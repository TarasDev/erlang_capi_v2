-module(capi_real_handler).

-include_lib("cp_proto/include/cp_payment_processing_thrift.hrl").
-include_lib("cp_proto/include/cp_domain_thrift.hrl").
-include_lib("cp_proto/include/cp_cds_thrift.hrl").
-include_lib("cp_proto/include/cp_merch_stat_thrift.hrl").
-include_lib("cp_proto/include/cp_user_interaction_thrift.hrl").

-behaviour(swagger_logic_handler).

%% API callbacks
-export([handle_request/3]).
-export([authorize_api_key/2]).

-spec authorize_api_key(OperationID :: swagger_api:operation_id(), ApiKey :: binary()) ->
    Result :: false | {true, #{binary() => any()}}.

authorize_api_key(OperationID, ApiKey) -> capi_auth:auth_api_key(OperationID, ApiKey).

-spec handle_request(
    OperationID :: swagger_api:operation_id(),
    Req :: #{},
    Context :: swagger_api:request_context()
) ->
    {Code :: non_neg_integer(), Headers :: [], Response :: #{}}.

handle_request(OperationID, Req, Context) ->
    capi_utils:logtag_process(operation_id, OperationID),
    _ = lager:info("Processing request ~p", [OperationID]),
    process_request(OperationID, Req, Context).

-spec process_request(
    OperationID :: swagger_api:operation_id(),
    Req :: #{},
    Context :: swagger_api:request_context()) ->
    {Code :: non_neg_integer(), Headers :: [], Response :: #{}}.

process_request(OperationID = 'CreateInvoice', Req, Context) ->
    InvoiceParams = maps:get('CreateInvoiceArgs', Req),
    RequestID = maps:get('X-Request-ID', Req),
    InvoiceContext = jsx:encode(genlib_map:get(<<"context">>, InvoiceParams)),
    PartyID = get_party_id(Context),
    Params =  #'payproc_InvoiceParams'{
        party_id = PartyID,
        description = genlib_map:get(<<"description">>, InvoiceParams),
        product  = genlib_map:get(<<"product">>, InvoiceParams),
        amount   = genlib_map:get(<<"amount">>, InvoiceParams),
        due      = genlib_map:get(<<"dueDate">>, InvoiceParams),
        currency = #'domain_CurrencyRef'{symbolic_code = genlib_map:get(<<"currency">>, InvoiceParams)},
        context  = #'Content'{
            type = <<"application/json">>,
            data = InvoiceContext
        },
        shop_id = genlib_map:get(<<"shopID">>, InvoiceParams)
    },
    UserInfo = get_user_info(Context),

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                invoicing,
                'Create',
                [UserInfo, Params],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, InvoiceID} ->
            Resp = #{
                <<"id">> => InvoiceID
            },
            {201, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'CreatePayment', Req, Context) ->
    InvoiceID = maps:get('invoiceID', Req),
    PaymentParams = maps:get('CreatePaymentArgs', Req),
    RequestID = maps:get('X-Request-ID', Req),
    Token = genlib_map:get(<<"paymentToolToken">>, PaymentParams),
    PaymentTool = decode_bank_card(Token),
    #{
        ip_address := IP
    } = get_peer_info(Context),
    PreparedIP = genlib:to_binary(inet:ntoa(IP)),
    EncodedSession = genlib_map:get(<<"paymentSession">>, PaymentParams),
    {ClientInfo, PaymentSession} = unwrap_session(EncodedSession),
    Params =  #payproc_InvoicePaymentParams{
        'payer' = #domain_Payer{
            payment_tool = PaymentTool,
            session = PaymentSession,
            client_info = #domain_ClientInfo{
                fingerprint = maps:get(<<"fingerprint">>, ClientInfo),
                ip_address = PreparedIP
            }
        }
    },
    UserInfo = get_user_info(Context),
    {Result, _NewContext} = service_call(invoicing,
        'StartPayment',
        [UserInfo, InvoiceID, Params],
        create_context(RequestID)
    ),
    case Result of
        {ok, PaymentID} ->
            Resp = #{
                <<"id">> => PaymentID
            },
            {201, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'CreatePaymentToolToken', Req, _Context) ->
    Params = maps:get('CreatePaymentToolTokenArgs', Req),
    RequestID = maps:get('X-Request-ID', Req),
    ClientInfo = maps:get(<<"clientInfo">>, Params),
    PaymentTool = maps:get(<<"paymentTool">>, Params),
    case PaymentTool of
        #{<<"paymentToolType">> := <<"CardData">>} ->
            {Month, Year} = parse_exp_date(genlib_map:get(<<"expDate">>, PaymentTool)),
            CardNumber = genlib:to_binary(genlib_map:get(<<"cardNumber">>, PaymentTool)),
            CardData = #'CardData'{
                pan  = CardNumber,
                exp_date = #'ExpDate'{
                    month = Month,
                    year = Year
                },
                cardholder_name = genlib_map:get(<<"cardHolder">>, PaymentTool),
                cvv = genlib_map:get(<<"cvv">>, PaymentTool)
            },
            {Result, _NewContext} = service_call(
                cds_storage,
                'PutCardData',
                [CardData],
                create_context(RequestID)
            ),
            case Result of
                {ok, #'PutCardDataResult'{
                    session = PaymentSession,
                    bank_card = BankCard
                }} ->
                    Token = encode_bank_card(BankCard),
                    Session = wrap_session(ClientInfo, PaymentSession),
                    Resp = #{
                        <<"token">> => Token,
                        <<"session">> => Session
                    },
                    {201, [], Resp};
                Error ->
                    process_request_error(OperationID, Error)
            end;
        _ ->
            {400, [], logic_error(wrong_payment_tool, <<"">>)}
    end;

process_request(OperationID = 'GetInvoiceByID', Req, Context) ->
    InvoiceID = maps:get(invoiceID, Req),
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    {Result, _NewContext} = service_call(
        invoicing,
        'Get',
        [UserInfo, InvoiceID],
        create_context(RequestID)
    ),
    case Result of
        {ok, #'payproc_InvoiceState'{invoice = #domain_Invoice{
            'id' = InvoiceID,
            'created_at' = _CreatedAt,
            'status' = {Status, _},
            'due' = DueDate,
            'product'= Product,
            'description' = Description,
            'cost' = #domain_Cash{
                amount = Amount,
                currency = #domain_Currency{
                    symbolic_code = Currency
                }
            },
            'context' = RawInvoiceContext,
            'shop_id' = ShopID
        }}} ->
         %%%   InvoiceContext = jsx:decode(RawInvoiceContext, [return_maps]), @TODO deal with non json contexts
            InvoiceContext = #{
                <<"context">> => RawInvoiceContext
            },
            Resp = #{
                <<"id">> => InvoiceID,
                <<"amount">> => Amount,
                <<"context">> => InvoiceContext,
                <<"currency">> => Currency,
                <<"description">> => Description,
                <<"dueDate">> => DueDate,
                <<"product">> => Product,
                <<"status">> => genlib:to_binary(Status),
                <<"shopID">> => ShopID
            },
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'FulfillInvoice', Req, Context) ->
    InvoiceID = maps:get(invoiceID, Req),
    RequestID = maps:get('X-Request-ID', Req),

    Params = maps:get('Reason', Req),
    Reason = maps:get(<<"reason">>, Params),

    UserInfo = get_user_info(Context),

    {Result, _NewContext} = service_call(
        invoicing,
        'Fulfill',
        [UserInfo, InvoiceID, Reason],
        create_context(RequestID)
    ),
    case Result of
        {ok, _} ->
            {200, [], #{}};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'RescindInvoice', Req, Context) ->
    InvoiceID = maps:get(invoiceID, Req),
    RequestID = maps:get('X-Request-ID', Req),

    Params = maps:get('Reason', Req),
    Reason = maps:get(<<"reason">>, Params),

    UserInfo = get_user_info(Context),
    {Result, _NewContext} = service_call(
        invoicing,
        'Rescind',
        [UserInfo, InvoiceID, Reason],
        create_context(RequestID)
    ),
    case Result of
        {ok, _} ->
            {200, [], #{}};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetInvoiceEvents', Req, Context) ->
    InvoiceID = maps:get(invoiceID, Req),
    _EventID = maps:get(eventID, Req),
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    EventRange = #'payproc_EventRange'{
        limit = maps:get(limit, Req),
        'after' = maps:get(eventID, Req)
    },
    {Result, _NewContext} = service_call(
        invoicing,
        'GetEvents',
        [UserInfo, InvoiceID, EventRange],
        create_context(RequestID)
    ),
    case Result of
        {ok, Events} when is_list(Events) ->
            Resp = [decode_event(I) || I <- Events],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetPaymentByID', Req, Context) ->
    PaymentID = maps:get(paymentID, Req),
    InvoiceID = maps:get(invoiceID, Req),
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    {Result, _NewContext} = service_call(
        invoicing,
        'GetPayment',
        [UserInfo, PartyID, PaymentID],
        create_context(RequestID)
    ),
    case Result of
        {ok, Payment} ->
            Resp = decode_payment(InvoiceID, Payment),
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetInvoices', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    Limit = genlib_map:get('limit', Req),
    Offset = genlib_map:get('offset', Req),
    InvoiceStatus = case genlib_map:get('status', Req) of
        undefined -> undefined;
        [Status] -> Status
    end,  %%@TODO deal with many statuses
    Query = #{
        <<"merchant_id">> => get_party_id(Context),
        <<"shop_id">> => genlib_map:get('shopID', Req),
        <<"invoice_id">> =>  genlib_map:get('invoiceID', Req),
        <<"from_time">> => genlib_map:get('fromTime', Req),
        <<"to_time">> => genlib_map:get('toTime', Req),
        <<"invoice_status">> => InvoiceStatus
    },
    QueryParams = #{
        <<"size">> => Limit,
        <<"from">> => Offset
    },
    Dsl = create_dsl(invoices, Query, QueryParams),
    {Result, _NewContext} = service_call(
        merchant_stat,
        'GetInvoices',
        [encode_stat_request(Dsl)],
        create_context(RequestID)
    ),
    case Result of
        {ok, #merchstat_StatResponse{data = {'invoices', Invoices}, total_count = TotalCount}} ->
            DecodedInvoices = [decode_invoice(I) || #merchstat_StatInvoice{invoice = I} <- Invoices],
            Resp = #{
                <<"invoices">> => DecodedInvoices,
                <<"totalCount">> => TotalCount
            },
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetPaymentConversionStats', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),

    StatType = payments_conversion_stat,
    Result = call_merchant_stat(StatType, Req, Context, RequestID),

    case Result of
        {ok, #merchstat_StatResponse{data = {'records', Stats}}} ->
            Resp = [decode_stat_response(StatType, S) || S <- Stats],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;


process_request(OperationID = 'GetPaymentRevenueStats', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),

    StatType = payments_turnover,
    Result = call_merchant_stat(StatType, Req, Context, RequestID),

    case Result of
        {ok, #merchstat_StatResponse{data = {'records', Stats}}} ->
            Resp = [decode_stat_response(StatType, S) || S <- Stats],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetPaymentGeoStats', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),

    StatType = payments_geo_stat,
    Result = call_merchant_stat(StatType, Req, Context, RequestID),

    case Result of
        {ok, #merchstat_StatResponse{data = {'records', Stats}}} ->
            Resp = [decode_stat_response(StatType, S) || S <- Stats],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetPaymentRateStats', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),

    StatType = customers_rate_stat,
    Result = call_merchant_stat(StatType, Req, Context, RequestID),

    case Result of
        {ok, #merchstat_StatResponse{data = {'records', Stats}}} ->
            Resp = [decode_stat_response(StatType, S) || S <- Stats],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetPaymentInstrumentStats', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    case maps:get(paymentInstrument, Req) of
        <<"card">> ->
            StatType = payments_card_stat,
            Result = call_merchant_stat(StatType, Req, Context, RequestID),
            case Result of
                {ok, #merchstat_StatResponse{data = {'records', Stats}}} ->
                    Resp = [decode_stat_response(StatType, S) || S <- Stats],
                    {200, [], Resp};
                Error ->
                    process_request_error(OperationID, Error)
            end
    end;

process_request(OperationID = 'CreateShop', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    Params = maps:get('CreateShopArgs', Req),
    ShopParams = #payproc_ShopParams{
        category = encode_category_ref(genlib_map:get(<<"categoryRef">>, Params)),
        details = encode_shop_details(genlib_map:get(<<"shopDetails">>, Params)),
        contractor = encode_contractor(genlib_map:get(<<"contractor">>, Params))
    },

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'CreateShop',
                [UserInfo, PartyID, ShopParams],
                RequestContext
            )
        end
    ),

    case Result of
        {ok, #payproc_ClaimResult{id = ID}} ->
            Resp = #{<<"claimID">> => ID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'ActivateShop', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),

    PartyID = get_party_id(Context),
    ShopID = maps:get(shopID, Req),

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'ActivateShop',
                [UserInfo, PartyID, ShopID],
                RequestContext
            )
        end
    ),

    case Result of
        {ok, #payproc_ClaimResult{id = ID}} ->
            Resp = #{<<"claimID">> => ID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'SuspendShop', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),

    PartyID = get_party_id(Context),
    ShopID = maps:get(shopID, Req),

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'SuspendShop',
                [UserInfo, PartyID, ShopID],
                RequestContext
            )
        end
    ),

    case Result of
        {ok, #payproc_ClaimResult{id = ID}} ->
            Resp = #{<<"claimID">> => ID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'UpdateShop', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    ShopID = maps:get(shopID, Req),
    Params = maps:get('UpdateShopArgs', Req),
    ShopUpdate = #payproc_ShopUpdate{
        category = genlib_map:get(<<"categoryRef">>, Params), %% @TODO check category ref later
        details = encode_shop_details(genlib_map:get(<<"shopDetails">>, Params)),
        contractor = encode_contractor(genlib_map:get(<<"contractor">>, Params))
    },
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'UpdateShop',
                [UserInfo, PartyID, ShopID, ShopUpdate],
                RequestContext
            )
        end
    ),

    case Result of
        {ok, #payproc_ClaimResult{id = ID}} ->
            Resp = #{<<"claimID">> => ID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetClaimByStatus', Req, Context) ->
    pending = maps:get(claimStatus, Req), %% @TODO think about other claim statuses here
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'GetPendingClaim',
                [UserInfo, PartyID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, Claim = #payproc_Claim{}} ->
            Resp = decode_claim(Claim),
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetClaimByID', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    ClaimID = maps:get(claimID, Req),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'GetClaim',
                [UserInfo, PartyID, ClaimID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, Claim = #payproc_Claim{}} ->
            Resp = decode_claim(Claim),
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'RevokeClaimByID', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    ClaimID = maps:get(claimID, Req),
    Params = maps:get('Reason', Req),
    Reason = maps:get(<<"reason">>, Params),

    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'RevokeClaim',
                [UserInfo, PartyID, ClaimID, Reason],
                RequestContext
            )
        end
    ),
    case Result of
        ok ->
            {200, [], #{}};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'SuspendMyParty', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'Suspend',
                [UserInfo, PartyID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, #payproc_ClaimResult{id = ClaimID}} ->
            Resp = #{<<"claimID">> => ClaimID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'ActivateMyParty', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'Activate',
                [UserInfo, PartyID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, #payproc_ClaimResult{id = ClaimID}} ->
            Resp = #{<<"claimID">> => ClaimID},
            {202, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetMyParty', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'Get',
                [UserInfo, PartyID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, #payproc_PartyState{
            party = Party
        }} ->
            Resp = decode_party(Party),
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(_OperationID = 'GetCategories', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    _ = get_user_info(Context),
    _ = get_party_id(Context),
    {{ok, Categories}, _Context} = capi_domain:get_categories(create_context(RequestID)),
    Resp = [decode_category(C) || C <- Categories],
    {200, [], Resp};

process_request(_OperationID = 'GetCategoryByRef', Req, Context0) ->
    RequestID = maps:get('X-Request-ID', Req),
    _ = get_user_info(Context0),
    _ = get_party_id(Context0),
    Ref = maps:get('categoryRef', Req),
    case capi_domain:get_category_by_ref(genlib:to_int(Ref), create_context(RequestID)) of
        {{ok, Category}, _Context} ->
            Resp = decode_category(Category),
            {200, [], Resp};
        {{error, not_found}, _Context} ->
            {404, [], general_error(<<"Category not found">>)}
    end;

process_request(OperationID = 'GetShopAccounts', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    ShopID = maps:get('shopID', Req),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'GetShopAccountSet',
                [UserInfo, PartyID, ShopID],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, A = #domain_ShopAccountSet{}} ->
            Resp = [decode_account_set(A)],
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(OperationID = 'GetAccountByID', Req, Context) ->
    RequestID = maps:get('X-Request-ID', Req),
    UserInfo = get_user_info(Context),
    PartyID = get_party_id(Context),
    AccountID = maps:get('accountID', Req),
    {Result, _} = prepare_party(
        Context,
        create_context(RequestID),
        fun(RequestContext) ->
            service_call(
                party_management,
                'GetShopAccountState',
                [UserInfo, PartyID, genlib:to_int(AccountID)],
                RequestContext
            )
        end
    ),
    case Result of
        {ok, #payproc_ShopAccountState{} = S} ->
            Resp = decode_shop_account_state(S),
            {200, [], Resp};
        Error ->
            process_request_error(OperationID, Error)
    end;

process_request(_OperationID, _Req, _Context) ->
    {501, [], <<"Not implemented">>}.

%%%

service_call(ServiceName, Function, Args, Context) ->
    {Result, Context} = cp_proto:call_service_safe(ServiceName, Function, Args, Context),
    _ = log_service_call_result(Result),
    {Result, Context}.

log_service_call_result(Result) ->
    _ = lager:debug("Service call result ~p", [Result]),
    log_service_call_result_(Result).

log_service_call_result_({ok, _}) ->
    lager:info("Service call result success");

log_service_call_result_({exception, Exception}) ->
    lager:error("Service call result exception ~p", [Exception]);

log_service_call_result_(_) ->
    ok.

create_context(ID) ->
    woody_client:new_context(genlib:to_binary(ID), capi_woody_event_handler).

logic_error(Code, Message) ->
    #{<<"code">> => genlib:to_binary(Code), <<"message">> => genlib:to_binary(Message)}.

limit_exceeded_error(Limit) ->
    logic_error(limit_exceeded, io_lib:format("Max limit: ~p", [Limit])).

general_error(Message) ->
    #{<<"message">> => genlib:to_binary(Message)}.

parse_exp_date(ExpDate) when is_binary(ExpDate) ->
    [Month,  Year] = binary:split(ExpDate, <<"/">>),
    {genlib:to_int(Month), 2000 + genlib:to_int(Year)}.

get_user_info(Context) ->
    #payproc_UserInfo{
        id = get_party_id(Context)
    }.

get_party_id(#{
    auth_context := AuthContext
}) ->
    maps:get(<<"sub">>, AuthContext).

get_peer_info(#{peer := Peer}) -> Peer.

encode_bank_card(#domain_BankCard{
    'token'  = Token,
    'payment_system' = PaymentSystem,
    'bin' = Bin,
    'masked_pan' = MaskedPan
}) ->
    base64url:encode(jsx:encode(#{
        <<"token">> => Token,
        <<"payment_system">> => PaymentSystem,
        <<"bin">> => Bin,
        <<"masked_pan">> => MaskedPan
    })).

encode_shop_details(undefined) ->
    undefined;

encode_shop_details(Details = #{
    <<"name">> := Name
}) ->
    #domain_ShopDetails{
        name = Name,
        description = genlib_map:get(<<"details">>, Details),
        location = genlib_map:get(<<"location">>, Details)
    }.

encode_category_ref(undefined) ->
    undefined;

encode_category_ref(Ref) ->
    #domain_CategoryRef{
        id = Ref
    }.

encode_contractor(undefined) ->
    undefined;

encode_contractor(#{
    <<"registeredName">> := RegisteredName,
    <<"legalEntity">> := _LegalEntity
}) ->
    #domain_Contractor{
        registered_name = RegisteredName,
        legal_entity = undefined
    }.

decode_bank_card(Encoded) ->
    #{
        <<"token">> := Token,
        <<"payment_system">> := PaymentSystem,
        <<"bin">> := Bin,
        <<"masked_pan">> := MaskedPan
    } = jsx:decode(base64url:decode(Encoded), [return_maps]),
    {bank_card, #domain_BankCard{
        'token'  = Token,
        'payment_system' = binary_to_existing_atom(PaymentSystem, utf8),
        'bin' = Bin,
        'masked_pan' = MaskedPan
    }}.

wrap_session(ClientInfo, PaymentSession) ->
    base64url:encode(jsx:encode(#{
        <<"clientInfo">> => ClientInfo,
        <<"paymentSession">> => PaymentSession
    })).

unwrap_session(Encoded) ->
    #{
        <<"clientInfo">> := ClientInfo,
        <<"paymentSession">> := PaymentSession
    } = jsx:decode(base64url:decode(Encoded), [return_maps]),
    {ClientInfo, PaymentSession}.

decode_event(#'payproc_Event'{
    'id' = EventID,
    'created_at' = CreatedAt,
    'payload' =  {'invoice_event', InvoiceEvent},
    'source' =  {'invoice', InvoiceID} %%@TODO deal with Party source
}) ->
    {EventType, EventBody} = decode_invoice_event(InvoiceID, InvoiceEvent),
    maps:merge(#{
        <<"id">> => EventID,
        <<"createdAt">> => CreatedAt,
        <<"eventType">> => EventType
    }, EventBody).

decode_invoice_event(_, {
    invoice_created,
    #payproc_InvoiceCreated{invoice = Invoice}
}) ->
    {<<"EventInvoiceCreated">>, #{
        <<"invoice">> => decode_invoice(Invoice)
    }};

decode_invoice_event(_, {
    invoice_status_changed,
    #payproc_InvoiceStatusChanged{status = {Status, _}}
}) ->
    {<<"EventInvoiceStatusChanged">>, #{
        <<"status">> => genlib:to_binary(Status)
    }};

decode_invoice_event(InvoiceID, {invoice_payment_event, Event}) ->
    decode_payment_event(InvoiceID, Event).

decode_payment_event(InvoiceID, {
    invoice_payment_started,
    #'payproc_InvoicePaymentStarted'{payment = Payment}
}) ->
    {<<"EventPaymentStarted">>, #{
        <<"payment">> => decode_payment(InvoiceID, Payment)
    }};

decode_payment_event(_, {
    invoice_payment_bound,
    #'payproc_InvoicePaymentBound'{payment_id = PaymentID}
}) ->
    {<<"EventPaymentBound">>, #{
        <<"paymentID">> => PaymentID
    }};

decode_payment_event(_, {
    invoice_payment_interaction_requested,
    #'payproc_InvoicePaymentInteractionRequested'{
        payment_id = PaymentID,
        interaction = Interaction
    }
}) ->
    {<<"EventInvoicePaymentInteractionRequested">>, #{
        <<"paymentID">> => PaymentID,
        <<"userInteraction">> => decode_user_interaction(Interaction)
    }};

decode_payment_event(_, {
    invoice_payment_status_changed,
    #'payproc_InvoicePaymentStatusChanged'{payment_id = PaymentID, status = {Status, _}}
}) ->
    {<<"paymentStatusChanged">>, #{
        <<"paymentID">> => PaymentID,
        <<"status">> => genlib:to_binary(Status)
    }}.

decode_payment(InvoiceID, #domain_InvoicePayment{
    'id' = PaymentID,
    'created_at' = CreatedAt,
    'status' = {Status, _},
    'payer' = #domain_Payer{
        payment_tool = {
            'bank_card',
            BankCard
        }
    }
}) ->
    #{
        <<"id">> =>  PaymentID,
        <<"invoiceID">> => InvoiceID,
        <<"createdAt">> => CreatedAt,
        <<"status">> => genlib:to_binary(Status),
        <<"paymentToolToken">> => encode_bank_card(BankCard)
    }.

decode_invoice(#domain_Invoice{
    'id' = InvoiceID,
    'created_at' = _CreatedAt, %%@TODO add it to the swagger spec
    'status' = {Status, _},
    'due'  = DueDate,
    'product' = Product,
    'description' = Description,
    'cost' = #domain_Cash{
        amount = Amount,
        currency = #domain_Currency{
            symbolic_code = Currency
        }
    },
    'context' = RawContext,
    'shop_id' = ShopID
}) ->
   %%% Context = jsx:decode(RawContext, [return_maps]), %%@TODO deal with non json contexts
    Context = #{
        <<"context">> => RawContext
    },
    genlib_map:compact(#{
        <<"id">> => InvoiceID,
        <<"shopID">> => ShopID,
        <<"amount">> => Amount,
        <<"currency">> => Currency,
        <<"context">> => Context,
        <<"dueDate">> => DueDate,
        <<"status">> => genlib:to_binary(Status),
        <<"product">> => Product,
        <<"description">> => Description
    }).

decode_party(#domain_Party{
    id = PartyID,
    blocking = Blocking,
    suspension = Suspension,
    shops = Shops
}) ->
    PreparedShops = maps:fold(
        fun(_, Shop, Acc) -> [decode_shop(Shop) | Acc] end,
        [],
        Shops
    ),
    #{
        <<"partyID">> => PartyID,
        <<"isBlocked">> => is_blocked(Blocking),
        <<"isSuspended">> => is_suspended(Suspension),
        <<"shops">> => PreparedShops
    }.

decode_shop(#domain_Shop{
    id = ShopID,
    blocking = Blocking,
    suspension = Suspension,
    category  = #domain_CategoryRef{
        id = CategoryRef
    },
    details  = ShopDetails,
    contractor = Contractor,
    contract  = ShopContract
}) ->
    genlib_map:compact(#{
        <<"shopID">> => ShopID,
        <<"isBlocked">> => is_blocked(Blocking),
        <<"isSuspended">> => is_suspended(Suspension),
        <<"categoryRef">> => CategoryRef,
        <<"shopDetails">> => decode_shop_details(ShopDetails),
        <<"contractor">> => decode_contractor(Contractor),
        <<"contract">> => decode_shop_contract(ShopContract)
    }).

decode_shop_details(undefined) ->
    undefined;

decode_shop_details(#domain_ShopDetails{
    name = Name,
    description = Description,
    location = Location
}) ->
    genlib_map:compact(#{
      <<"name">> => Name,
      <<"description">> => Description,
      <<"location">> => Location
    }).

decode_contractor(undefined) ->
    undefined;

decode_contractor(#domain_Contractor{
    registered_name = RegisteredName,
    legal_entity = _LegalEntity
}) ->
    #{
        <<"registeredName">> => RegisteredName,
        <<"legalEntity">> => <<"dummy_entity">> %% @TODO Fix legal entity when thrift is ready
    }.

decode_shop_contract(undefined) ->
    undefined;

decode_shop_contract(#domain_ShopContract{
    number = Number,
    system_contractor = #domain_ContractorRef{
        id = ContractorRef
    },
    concluded_at = ConcludedAt,
    valid_since = ValidSince,
    valid_until = ValidUntil,
    terminated_at = _TerminatedAt %% @TODO show it to the client?
}) ->
    #{
        <<"number">> => Number,
        <<"systemContractorRef">> => ContractorRef,
        <<"concludedAt">> => ConcludedAt,
        <<"validSince">> => ValidSince,
        <<"validUntil">> => ValidUntil
    }.

is_blocked({blocked, _}) ->
    true;
is_blocked({unblocked, _}) ->
    false.

is_suspended({suspended, _}) ->
    true;
is_suspended({active, _}) ->
    false.

decode_suspension({suspended, _}) ->
    #{<<"suspensionType">> => <<"suspended">>};

decode_suspension({active, _}) ->
    #{<<"suspensionType">> => <<"active">>}.

decode_stat_response(payments_conversion_stat, Response) ->
    #{
        <<"offset">> => genlib:to_int(maps:get(<<"offset">>, Response)),
        <<"successfulCount">> => genlib:to_int(maps:get(<<"successful_count">>, Response)),
        <<"totalCount">> => genlib:to_int(maps:get(<<"total_count">>, Response)),
        <<"conversion">> => genlib:to_float(maps:get(<<"conversion">>, Response))
    };

decode_stat_response(payments_geo_stat, Response) ->
    #{
        <<"offset">> => genlib:to_int(maps:get(<<"offset">>, Response)),
        <<"cityName">> => maps:get(<<"city_name">>, Response),
        <<"currency">> => maps:get(<<"currency_symbolic_code">>, Response),
        <<"profit">> => genlib:to_int(maps:get(<<"amount_with_fee">>, Response)),
        <<"revenue">> => genlib:to_int(maps:get(<<"amount_without_fee">>, Response))
    };

decode_stat_response(payments_turnover, Response) ->
    #{
        <<"offset">> => genlib:to_int(maps:get(<<"offset">>, Response)),
        <<"currency">> => maps:get(<<"currency_symbolic_code">>, Response),
        <<"profit">> => genlib:to_int(maps:get(<<"amount_with_fee">>, Response)),
        <<"revenue">> => genlib:to_int(maps:get(<<"amount_without_fee">>, Response))
    };

decode_stat_response(customers_rate_stat, Response) ->
    #{
        <<"uniqueCount">> => genlib:to_int(maps:get(<<"unic_count">>, Response))
    };

decode_stat_response(payments_card_stat, Response) ->
    #{
        <<"offset">> => genlib:to_int(maps:get(<<"offset">>, Response)),
        <<"totalCount">> =>  genlib:to_int(maps:get(<<"total_count">>, Response)),
        <<"paymentSystem">> =>  maps:get(<<"payment_system">>, Response),
        <<"profit">> => genlib:to_int(maps:get(<<"amount_with_fee">>, Response)),
        <<"revenue">> =>  genlib:to_int(maps:get(<<"amount_without_fee">>, Response))
    }.

create_dsl(QueryType, QueryBody, QueryParams) when
    is_atom(QueryType),
    is_map(QueryBody),
    is_map(QueryParams) ->
    Query = maps:put(genlib:to_binary(QueryType), genlib_map:compact(QueryBody), #{}),
    Basic = #{
        <<"query">> => Query
    },
    maps:merge(Basic, genlib_map:compact(QueryParams)).

decode_claim(#payproc_Claim{
    id = ID,
    status = Status,
    changeset = ChangeSet
}) ->
    #{
        <<"id">> => ID,
        <<"status">> => decode_claim_status(Status),
        <<"changeset">> => decode_party_changeset(ChangeSet)
    }.

decode_claim_status({'pending', _}) ->
    #{
        <<"status">> => <<"ClaimPending">>
    };
decode_claim_status({'accepted', _}) ->
    #{
        <<"status">> =><<"ClaimAccepted">>
    };

decode_claim_status({'denied', #payproc_ClaimDenied{
    reason = Reason
}}) ->
    #{
        <<"status">> => <<"ClaimDenied">>,
        <<"reason">> => Reason
    };

decode_claim_status({'revoked', _}) ->
    #{
        <<"status">> =><<"ClaimRevoked">>
    }.

decode_party_changeset(PartyChangeset) ->
    [decode_party_modification(PartyModification) || PartyModification <- PartyChangeset].

decode_party_modification({suspension, Suspension}) ->
    #{
        <<"modificationType">> => <<"PartySuspension">>,
        <<"details">> => decode_suspension(Suspension)
    };

decode_party_modification({shop_creation, Shop}) ->
    #{
        <<"modificationType">> => <<"ShopCreation">>,
        <<"shop">> => decode_shop(Shop)
    };

decode_party_modification({
    shop_modification,
    #payproc_ShopModificationUnit{
        id = ShopID,
        modification = ShopModification
    }
}) ->
    #{
        <<"modificationType">> => <<"ShopModificationUnit">>,
        <<"shopID">> => ShopID,
        <<"details">> => decode_shop_modification(ShopModification)
    }.

decode_shop_modification({suspension, Suspension}) ->
    #{
        <<"modificationType">> => <<"ShopSuspension">>,
        <<"details">> => decode_suspension(Suspension)
    };

decode_shop_modification({
    update,
    #payproc_ShopUpdate{
        category = Category,
        details = ShopDetails,
        contractor = Contractor
    }
}) ->
    #{
        <<"modificationType">> => <<"ShopUpdate">>,
        <<"details">> => genlib_map:compact(#{
            <<"shopDetails">> => decode_shop_details(ShopDetails),
            <<"contractor">> => decode_contractor(Contractor),
            <<"categoryRef">> => decode_category_ref(Category)
        })
    };

decode_shop_modification({
    accounts_created,
    #payproc_ShopAccountSetCreated{
        accounts = AccountSet
    }
}) ->
    #{
        <<"modificationType">> => <<"ShopAccountCreated">>,
        <<"account">> => decode_account_set(AccountSet)
    }.

decode_category(#domain_CategoryObject{
    ref = #domain_CategoryRef{
        id = CategoryRef
    },
    data = #domain_Category{
        name = Name,
        description = Description
    }
}) ->
    genlib_map:compact(#{
        <<"name">> => Name,
        <<"categoryRef">> => CategoryRef,
        <<"description">> => Description
    }).

decode_category_ref(undefined) ->
    undefined;

decode_category_ref(#domain_CategoryRef{
    id = CategoryRef
}) ->
    CategoryRef.

decode_account_set(#domain_ShopAccountSet{
    general = GeneralID,
    guarantee = GuaranteeID
}) ->
    #{
        %% @FIXME Why this ints are promised as strings in swagger?
        <<"generalID">> => genlib:to_binary(GeneralID),
        <<"guaranteeID">> => genlib:to_binary(GuaranteeID)
    }.

decode_shop_account_state(#payproc_ShopAccountState{
    account_id = AccountID,
    own_amount = OwnAmount,
    available_amount = AvailableAmount,
    currency = #domain_Currency{
        symbolic_code = SymbolicCode
    }
}) ->
    #{
        <<"id">> => genlib:to_binary(AccountID),
        <<"ownAmount">> => OwnAmount,
        <<"availableAmount">> => AvailableAmount,
        <<"currency">> => SymbolicCode
    }.

decode_user_interaction({redirect, BrowserRequest}) ->
    #{
        <<"interactionType">> => <<"redirect">>,
        <<"request">> => decode_browser_request(BrowserRequest)
    }.

decode_browser_request({get_request, #'BrowserGetRequest'{
    uri = UriTemplate
}}) ->
    #{
        <<"requestType">> => <<"browserGetRequest">>,
        <<"uriTemplate">> => UriTemplate
    };

decode_browser_request({post_request, #'BrowserPostRequest'{
    uri = UriTemplate,
    form = UserInteractionForm
}}) ->
    #{
        <<"requestType">> => <<"browserPostRequest">>,
        <<"uriTemplate">> => UriTemplate,
        <<"form">> => decode_user_interaction_form(UserInteractionForm)
    }.

decode_user_interaction_form(Form) ->
    maps:fold(
        fun(K, V, Acc) ->
            F = #{
                <<"key">> => K,
                <<"template">> => V
            },
            [F | Acc]
        end,
        [],
        Form
    ).

encode_stat_request(Dsl) when is_map(Dsl) ->
    encode_stat_request(jsx:encode(Dsl));

encode_stat_request(Dsl) when is_binary(Dsl) ->
    #merchstat_StatRequest{
        dsl = Dsl
    }.

create_stat_dsl(StatType, Req, Context) ->
    FromTime = genlib_map:get('fromTime', Req),
    ToTime = genlib_map:get('toTime', Req),
    SplitInterval = case StatType of
        customers_rate_stat ->
            get_time_diff(FromTime, ToTime);
        _ ->
            SplitUnit = genlib_map:get('splitUnit', Req),
            SplitSize = genlib_map:get('splitSize', Req),
            get_split_interval(SplitSize, SplitUnit)
    end,

    Query = #{
        <<"merchant_id">> => get_party_id(Context),
        <<"shop_id">> => genlib_map:get('shopID', Req),
        <<"from_time">> => FromTime,
        <<"to_time">> => ToTime,
        <<"split_interval">> => SplitInterval
    },
    create_dsl(StatType, Query, #{}).

call_merchant_stat(StatType, Req, Context, RequestID) ->
    Dsl = create_stat_dsl(StatType, Req, Context),
    {Result, _NewContext} = service_call(
        merchant_stat,
        'GetStatistics',
        [encode_stat_request(Dsl)],
        create_context(RequestID)
    ),
    Result.

get_split_interval(SplitSize, minute) ->
    SplitSize * 60;

get_split_interval(SplitSize, hour) ->
    SplitSize * 60 * 60;

get_split_interval(SplitSize, day) ->
    SplitSize * 60 * 60 * 24;

get_split_interval(SplitSize, week) ->
    SplitSize * 60 * 60 * 24 * 7;

get_split_interval(SplitSize, month) ->
    SplitSize * 60 * 60 * 24 * 30;

get_split_interval(SplitSize, year) ->
    SplitSize * 60 * 60 * 24 * 365.

get_time_diff(From, To) ->
    {DateFrom, TimeFrom} = parse_rfc3339_datetime(From),
    {DateTo, TimeTo} = parse_rfc3339_datetime(To),
    UnixFrom = genlib_time:daytime_to_unixtime({DateFrom, TimeFrom}),
    UnixTo = genlib_time:daytime_to_unixtime({DateTo, TimeTo}),
    UnixTo - UnixFrom.

parse_rfc3339_datetime(DateTime) ->
    {ok, {DateFrom, TimeFrom, _, _}} = rfc3339:parse(DateTime),
    {DateFrom, TimeFrom}.

process_request_error(_, {exception, #payproc_InvalidUser{}}) ->
    {400, [], logic_error(invalid_user, <<"Ivalid user">>)};

process_request_error(_, {exception, #'InvalidRequest'{}}) ->
    {400, [], logic_error(invalid_request, <<"Request can't be processed">>)};

process_request_error(_, {exception, #payproc_UserInvoiceNotFound{}} ) ->
    {404, [], general_error(<<"Invoice not found">>)};

process_request_error(_, {exception, #payproc_ClaimNotFound{}} ) ->
    {404, [], general_error(<<"Claim not found">>)};

process_request_error(_,  {exception, #payproc_InvalidInvoiceStatus{}} ) ->
    {400, [], logic_error(invalid_invoice_status, <<"Invalid invoice status">>)};

process_request_error(_, {exception, #payproc_InvoicePaymentPending{}}) ->
    {400, [], logic_error(invalid_payment_status, <<"Invalid payment status">>)};

process_request_error(_, {exception, #payproc_InvalidShopStatus{}}) ->
    {400, [], logic_error(invalid_shop_status, <<"Invalid shop status">>)};

process_request_error(_, {exception, #payproc_PartyNotFound{}}) ->
    {404, [],  general_error(<<"Party not found">>)};

process_request_error(_,  {exception, #'InvalidCardData'{}}) ->
    {400, [], logic_error(invalid_request, <<"Card data is invalid">>)};

process_request_error(_, {exception, #'KeyringLocked'{}}) ->
    {503, [], <<"">>};

process_request_error(_, {exception, #payproc_EventNotFound{}}) ->
    {404, [], general_error(<<"Event not found">>)};

process_request_error(_, {exception, #payproc_ShopNotFound{}}) ->
    {404, [], general_error(<<"Shop not found">>)};

process_request_error(_, {exception, #payproc_InvoicePaymentNotFound{}} ) ->
    {404, [], general_error(<<"Payment not found">>)};

process_request_error(_, {exception, #merchstat_DatasetTooBig{limit = Limit}}) ->
    {400, [], limit_exceeded_error(Limit)}.


prepare_party(Context, RequestContext0, ServiceCall) ->
    {Result0, RequestContext1} = ServiceCall(RequestContext0),
    case Result0 of
        {exception, #payproc_PartyNotFound{}} ->
            _ = lager:info("Attempting to create a missing party"),
            {Result1, RequestContext2} = create_party(Context, RequestContext1),
            case Result1 of
                ok -> ServiceCall(RequestContext2);
                Error -> {Error, RequestContext2}
            end;
        _ ->
            {Result0, RequestContext1}
    end.

create_party(Context, RequestContext) ->
    PartyID = get_party_id(Context),
    UserInfo = get_user_info(Context),
    {Result, NewRequestContext} = service_call(
        party_management,
        'Create',
        [UserInfo, PartyID],
        RequestContext
    ),
    R = case Result of
        ok ->
            ok;
        {exception, #payproc_PartyExists{}} ->
            ok;
        Error ->
            Error
    end,
    {R, NewRequestContext}.

