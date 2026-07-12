%% FFI helpers for the Fiducia client's blocking acquire poll loops.
%% Kept tiny and dependency-free: monotonic clock, a sleep, and a holder id.
-module(fiducia_ffi).
-export([monotonic_ms/0, sleep/1, gen_holder/0]).

%% Monotonic milliseconds for deadline math. May be negative (arbitrary origin);
%% only differences are used, so that is fine.
monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% Sleep for a non-negative number of milliseconds, returning Gleam's Nil.
sleep(Ms) when is_integer(Ms), Ms > 0 ->
    timer:sleep(Ms),
    nil;
sleep(_) ->
    nil.

%% Stable, unique-ish holder id: "fdc-" + 16 lowercase hex chars (8 random bytes).
gen_holder() ->
    <<"fdc-", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>.
