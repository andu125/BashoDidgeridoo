%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.

-module(riak_music_fitting).
-behaviour(riak_pipe_vnode_worker).
-include("riak_music.hrl").

-export([
         init/2,
         process/3,
         done/1
        ]).

-record(state, {partition, method}).

%% API
init(Partition, _FittingDetails) ->
    %% TODO: Test for various methods of playing sounds.
    Method = riak_music_utils:detect_audio_method(),
    {ok, #state { partition=Partition, method=Method }}.

process({play, _Controller, MidiNote, Amplitude, Duration}, _Last, State) ->
    %% Print out the note...
    if
        Duration < 0.1 -> Note = [9834];
        Duration < 0.4 -> Note = [9833];
        true -> Note = [9835]
    end,
    Offset = lists:max([(MidiNote - 40) * 2, 0]),
    String = lists:flatten([string:copies(" ", Offset), Note, "\n"]),
    io:format(String),
    
    %% Play the note...
    play(State#state.method, MidiNote, Amplitude, Duration),
    {ok, State}.

done(_State) ->
    ok.

%% PRIVATE FUNCTIONS

play(Method, MidiNote, Amplitude, Duration) ->
    %% Generate the sound file...
    Filename = lists:flatten(io_lib:format("./notes/note_~w_~w_~w.au", [MidiNote, Duration, Amplitude])),
    case filelib:is_regular(Filename) of
        true ->
            ok;
        false ->
            Data = generate_au(MidiNote, Amplitude, Duration),
            filelib:ensure_dir(Filename),
            file:write_file(Filename, Data)
    end,

    %% Play the sound file.
    play(Method, Filename).

%% Generate the sh command to play an audio file.
play(afplay, Filename) ->
    spawn(fun() -> os:cmd("afplay " ++ Filename) end);
play(aplay, Filename) ->
    spawn(fun() -> os:cmd("aplay " ++ Filename) end);
play(Unknown, _) ->
    ?PRINT({unknown_audio_method, Unknown}).

%% Return the bytes for an .au file of the requested duration,
%% amplitude, and pitch.
%% @param MidiNote is a midi note from 0 to 127.
%% @param Amplitude from 0 to 1.0
%% @param Duration in seconds.
%%
%% Info gleaned from:
%% - http://blogs.msdn.com/b/dawate/archive/2009/06/24/intro-to-audio-programming-part-3-synthesizing-simple-wave-audio-using-c.aspx
%% - http://en.wikipedia.org/wiki/Au_file_format
generate_au(MidiNote, Amplitude, Duration) ->
    %% Calculate some vars...
    Frequency = 261 * math:pow(2, (MidiNote-60)/12.0),
    NumSamples = trunc(?SAMPLERATE * Duration),
    T = (math:pi() * 2 * Frequency) / ?SAMPLERATE,

    %% Generate the raw PCM data
    F = fun(X) ->
                %% Apply a simple fade in and out of the note to make
                %% it sound less harsh.
                if 
                    (X < NumSamples * 0.1) ->
                        Scale = (X / (NumSamples * 0.1));
                    (X > NumSamples * 0.8) ->
                        Scale = (1 - (X - NumSamples * 0.8) / (NumSamples * 0.2));
                    true ->
                        Scale = 1
                end,
                Value = trunc(32767 * Amplitude * Scale * math:sin(T * X)),
                [<<Value:16/big-signed-integer>> || _ <- lists:seq(1, ?CHANNELS)]
        end,
    Data = iolist_to_binary([F(X) || X <- lists:seq(1, NumSamples)]),
    Size = size(Data),
    
    %% From 
    <<
      ".snd",                    % Magic Number
      0024:32/unsigned-integer,  % Data offset
      Size:32/unsigned-integer,  % Data size
      0003:32/unsigned-integer,  % 16-bit linear PCM
      ?SAMPLERATE:32/unsigned-integer,  % 8000 sample rate
      ?CHANNELS:32/unsigned-integer,  % Two channels
      Data/binary
    >>.
