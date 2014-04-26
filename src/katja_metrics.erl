% Copyright (c) 2014, Daniel Kempkens <daniel@kempkens.io>
%
% Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted,
% provided that the above copyright notice and this permission notice appear in all copies.
%
% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
% WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
% DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
% NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%
% @author Daniel Kempkens <daniel@kempkens.io>
% @copyright 2014 Daniel Kempkens
% @version 1.0
% @doc The <em>katja_metrics</em> module is responsible for sending metrics to Riemann.

-module(katja_metrics).
-behaviour(gen_server).

-include("katja_types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(COMMON_FIELDS, [time, state, service, host, description, tags, ttl]).

% API
-export([
  start_link/0,
  send_event/1
]).

% gen_server
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

% API

% @doc Starts the metrics server.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% @doc Sends an event to Riemann.
-spec send_event(katja:event()) -> ok | {error, term()}.
send_event(Data) ->
  Event = create_event(Data),
  gen_server:call(?MODULE, {send_event, Event}).

% gen_server

% @hidden
init([]) ->
  {ok, State} = katja_connection:connect(),
  {ok, State}.

% @hidden
handle_call({send_event, Event}, _From, State) ->
  Msg = create_message([Event]),
  {Reply, State2} = send_message(Msg, State),
  {reply, Reply, State2};
handle_call(terminate, _From, State) ->
  {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
  {reply, ignored, State}.

% @hidden
handle_cast(_Msg, State) ->
  {noreply, State}.

% @hidden
handle_info(_Msg, State) ->
  {noreply, State}.

% @hidden
terminate(normal, State) ->
  ok = katja_connection:disconnect(State),
  ok.

% @hidden
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

% Private

-spec create_event(katja:event()) -> riemannpb_event().
create_event(Data) ->
  Event = #riemannpb_event{},
  Event2 = lists:foldr(fun(K, E) ->
    case lists:keyfind(K, 1, Data) of
      {K, V} -> set_event_field(K, V, E);
      false -> E
    end
  end, Event, [attributes|?COMMON_FIELDS]),
  Metric = lists:keyfind(metric, 1, Data),
  set_event_field(metric, Metric, Event2).

-spec set_event_field(atom(), term(), riemannpb_event()) -> riemannpb_event().
set_event_field(time, V, E) -> E#riemannpb_event{time=V};
set_event_field(state, V, E) -> E#riemannpb_event{state=V};
set_event_field(service, V, E) -> E#riemannpb_event{service=V};
set_event_field(host, V, E) -> E#riemannpb_event{host=V};
set_event_field(description, V, E) -> E#riemannpb_event{description=V};
set_event_field(tags, V, E) -> E#riemannpb_event{tags=V};
set_event_field(ttl, V, E) -> E#riemannpb_event{ttl=V};
set_event_field(attributes, V, E) -> E#riemannpb_event{attributes=V};
set_event_field(metric, false, E) -> E#riemannpb_event{metric_f = 0.0, metric_sint64 = 0};
set_event_field(metric, {metric, V}, E) when is_integer(V) ->
  E#riemannpb_event{metric_f = V * 1.0, metric_sint64 = V};
set_event_field(metric, {metric, V}, E) -> E#riemannpb_event{metric_f = V, metric_d = V}.

-spec create_message([riemannpb_entity()]) -> riemannpb_message().
create_message(Entities) ->
  {Events, States} = lists:splitwith(fun(Entity) ->
    if
      is_record(Entity, riemannpb_event) -> true;
      true -> false
    end
  end, Entities),
  #riemannpb_msg{events=Events, states=States}.

-spec send_message(riemannpb_message(), katja_connection:state()) -> {ok, katja_connection:state()} | {{error, term()}, katja_connection:state()}.
send_message(Msg, State) ->
  Msg2 = katja_pb:encode_riemannpb_msg(Msg),
  BinMsg = iolist_to_binary(Msg2),
  case katja_connection:send_message(BinMsg, State) of
    {{ok, _RetMsg}, State2} -> {ok, State2};
    {{error, Reason}, State2} -> {{error, Reason}, State2}
  end.

% Tests (private functions)

-ifdef(TEST).
create_event_test() ->
  Data = [
    {time, 1},
    {state, "online"},
    {service, "katja"},
    {host, "localhost"},
    {description, "katja test"},
    {tags, ["foo", "bar"]}
  ],
  ?assertMatch(#riemannpb_event{time=1, state="online", service="katja", host="localhost", description="katja test", tags=["foo", "bar"]}, create_event(Data)),
  ?assertMatch(#riemannpb_event{metric_f=0.0, metric_sint64=0}, create_event(Data)),
  ?assertMatch(#riemannpb_event{metric_f=1.0, metric_sint64=1}, create_event(Data ++ [{metric, 1}])),
  ?assertMatch(#riemannpb_event{metric_f=2.0, metric_d=2.0}, create_event(Data ++ [{metric, 2.0}])),
  ?assertMatch(#riemannpb_event{ttl=900.1, attributes=[{"foo", "bar"}]}, create_event(Data ++ [{ttl, 900.1}, {attributes, [{"foo", "bar"}]}])).

create_message_test() ->
  Data = [
    {time, 1},
    {state, "online"},
    {service, "katja"},
    {host, "localhost"},
    {description, "katja test"},
    {tags, ["foo", "bar"]}
  ],
  Event = create_event(Data),
  ?assertMatch(#riemannpb_msg{events=[#riemannpb_event{service="katja", host="localhost", description="katja test"}]}, create_message([Event])).
-endif.
