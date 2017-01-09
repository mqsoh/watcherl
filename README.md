# Watcherl

This is a Docker image that will start an Erlang shell. It watches `src/` for
changes and recompiles them. It checks for changes in `ebin/` and reloads
modules.

I'm using [`compile:file/2`](http://erlang.org/doc/man/compile.html#file-2).
You can specify compiler arguments in the environment variable
`WATCHERL_COMPILER_OPTIONS`. The default value is `[verbose, report, {outdir,
"ebin"}]`; if you define new options they override the default so I recommend
adding to that list. For example, if you use eunit for testing and need do
define the `TEST` macro:

    [verbose, report, {outdir, "ebin"}, {d, 'TEST'}]

You can augment the code path with the environment variable
[ERL_LIBS](http://erlang.org/doc/man/code.html) but there's no code reloading.

Here's the minimal `docker run` command you need to run.

    docker run --interactive --tty --rm --volume $(pwd):/workdir mqsoh/watcherl

Here's one where I'm developing an application with dependencies in `deps/` and
have eunit tests.

    docker run --interactive --tty --rm --volume $(pwd):/workdir --env "ERL_LIBS=$(find deps -type d -name ebin)" --env "WATCHERL_COMPILER_OPTIONS=[verbose, report, {outdir, \"ebin\"}, {d, 'TEST'}]" mqsoh/watcherl



# Outline of the Dockerfile

I'm going to use `inotify-tools` to watch the `workdir`. It will send messages
to a process in the shell that's started.


###### file:Dockerfile
    # This file was generated from the README.md in the GitHub repository.
    FROM erlang:19.2

    <<Install inotify-tools.>>
    <<The Bash side.>>
    <<The Erlang side.>>



# Install inotify-tools.

The official Erlang image is based on Debian Jessie; `inotify-tools` is in the
package manager.

###### Install inotify-tools.
    RUN apt-get update \
        && apt-get install -y inotify-tools \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

The `apt-get clean` and `rm ...` cleans up any unnecessary `apt` stuff. I saw
this suggested in an article, but I didn't save the link.



# The Bash side.

The `WORKDIR /workdir` line is a convention I like to use in my images; I
always have a `--volume $(pwd):/workdir`. The script to start the shell will be
installed in the image from `files/watcherl.sh`

###### The Bash side.
    WORKDIR /workdir
    COPY files/watcherl.sh /usr/local/bin/watcherl.sh
    RUN chmod +x /usr/local/bin/watcherl.sh
    CMD ["watcherl.sh"]

I can use `inotifywait` to be notified of changes in `src` and `ebin`.

###### file:files/watcherl.sh
    #!/bin/bash
    # This file was generated from the README.md.

    inotifywait --monitor --event close_write,moved_to --format '%w%f' ebin src | while read file; do
        case $file in
            <<Handle changes.>>
        esac
    done &

    <<Start the shell.>>

I've used inotifywait before, and I usually just use the `close_write` event to
identify changes to a file. However, it seems that the Erlang compiler's
sequence of events is this:

    src/ OPEN foo.erl
    src/ ACCESS foo.erl
    src/ ACCESS foo.erl
    src/ CLOSE_NOWRITE,CLOSE foo.erl
    ebin/ CREATE foo.bea#
    ebin/ OPEN foo.bea#
    ebin/ MODIFY foo.bea#
    ebin/ CLOSE_WRITE,CLOSE foo.bea#
    ebin/ MOVED_FROM foo.bea#
    ebin/ MOVED_TO foo.beam

It initially writes to `foo.bea#` and them moves that to the `.beam` extension.
That's why `moved_to` is included in the list of events.

### Sending Messages to the Shell

When files are changed I need to send a message to the running shell. I'll
enumerate those processes below, but first I have to be able to send a message
to them! Here is [an example of sending a message between processes on the same
node][].  And here's my abbreviated example with a bash one-liner.

    erl -sname one
    > register(my_process, spawn(fun () -> receive Any -> io:format("Got: ~w~n", [Any]) end end)).
    true

And from the bash prompt:

    $ erl -noshell -sname two -eval '{my_process, list_to_atom("one@" ++ net_adm:localhost())} ! from_the_shell' -s init stop

In the Erlang shell, you'll see:

    Got: from_the_shell

The `-sname <name>` puts Erlang in distributed mode and lets me send a message.
So, all I need to do is pick names for the process that will compile and reload
files. I'll call them `watcherl_compiler` and `watcherl_reloader`.

Remember, these following sections are inside the `case` statement in `watcherl.sh`.

###### Handle changes.
    *.erl)
        erlang_code="{watcherl_compiler, list_to_atom(\"watcherl@\" ++ net_adm:localhost())} ! \"$file\""
        erl -noshell -sname "watcherl_sh_src_$RANDOM" -eval "$erlang_code" -s init stop &
        ;;

    *.beam)
        module_name=$(basename "$file" .beam)
        erlang_code="{watcherl_reloader, list_to_atom(\"watcherl@\" ++ net_adm:localhost())} ! \"$module_name\""

        erl -noshell -sname "watcherl_sh_beam_$RANDOM" -eval "$erlang_code" -s init stop &
        ;;

The `erl ...` calls need to be backgrounded because, in my experience, it will
block the processing of other inotifywait events if you don't.

I called the shell `watcherl` above (the `watcherl@` parts), so I need to call
it that when I start the shell. Also, I'm going to start these processes in the
`.erlang`, but I want the image to be useful in other ways so I'll set up a
command line flag to turn them on.

###### Start the shell.
    erl -watcherl_on -sname watcherl -pa ebin



# The Erlang side.

[Erlang supports shell configuration in a `.erlang` file.][] The commands in
this file are run in the shell as if a user had typed them (in the same
context). You can define helper functions here!

I need to add the `.erlang` to the Docker image.

###### The Erlang side.
    COPY files/dot_erlang /root/.erlang

The file itself needs to start the compiler and reloader processes if they're
turned on from the command line.

###### file:files/dot_erlang
    % This file was generated from the README.md.
    case init:get_argument(watcherl_on) of
        {ok, _} ->
            io:format("~nwatcherl: Starting the compiler and BEAM reloader.~n"),
            <<Start the compiler.>>
            ,
            <<Start the BEAM reloader.>>
            ,
            <<Compile initial files.>>
            ;
        _ -> ok
    end.

The dangling `,` and `;` mean that I can define those code sections in the same
way, without terminating the term, in the following sections.

I'd like to be able to override the compiler options with an environment
variable. It's not straight forward. `term_to_binary` and `binary_to_term` uses
a binary format and I couldn't figure out how to pass them a bitstring. I found
[a solution on a mailing
list](http://erlang.org/pipermail/erlang-questions/2007-August/028652.html)
that is a bit more convoluted. It makes sense, though. For the sake of
archiving, here's the example from that post.

    > TupleListStr = "[{a, b, c}, {d, e}]".
    "[{a, b, c}, {d, e}]"
    > {ok, TermTokens, _EndLine} = erl_scan:string(TupleListStr ++ ".").
    {ok,[{'[',1},
        {'{',1},
        {atom,1,a},
        {',',1},
        {atom,1,b},
        {',',1},
        {atom,1,c},
        {'}',1},
        {',',1},
        {'{',1},
        {atom,1,d},
        {',',1},
        {atom,1,e},
        {'}',1},
        {']',1},
        {dot,1}],
       1}
    > {ok, Exprs} = erl_parse:parse_exprs(TermTokens).
    {ok,[{cons,1,
              {tuple,1,[{atom,1,a},{atom,1,b},{atom,1,c}]},
              {cons,1,{tuple,1,[{atom,1,d},{atom,1,e}]},{nil,1}}}]}
    > {value, TupleList, _NewBindings} = erl_eval:exprs(Exprs, []).
    {value,[{a,b,c},{d,e}],[]}
    > TupleList.
    [{a,b,c},{d,e}]

###### Start the compiler.
    Compiler_options = begin
        Given_options = os:getenv("WATCHERL_COMPILER_OPTIONS", "[verbose, report, {outdir, \"ebin\"}]") ++ ".",
        {ok, Tokens, _End_location} = erl_scan:string(Given_options),
        {ok, Expressions} = erl_parse:parse_exprs(Tokens),
        {value, Value, _New_bindings} = erl_eval:exprs(Expressions, []),
        Value
    end,
    register(watcherl_compiler, spawn(fun F() ->
        receive
            File_name ->
                case compile:file(File_name, Compiler_options) of
                    error ->
                        io:format("~nwatcherl: Unspecified error compiling: ~s~n", [File_name]);
                    {error, Errors, Warnings} ->
                        io:format("~nwatcherl: Failed compiling ~s with errors (~p) and warnings (~p).~n", [File_name, Errors, Warnings]);
                    _ ->
                        io:format("~nwatcherl: Compiled: ~s~n", [File_name])
                end
        end,
        F()
    end))

###### Start the BEAM reloader.
    register(watcherl_reloader, spawn(fun F() ->
        receive
            Module_name ->
                io:format("~nwatcherl: Reloading: ~s~n", [Module_name]),
                Module = list_to_atom(Module_name),
                code:purge(Module),
                code:load_file(Module)
        end,
        F()
    end))

To avoid unnecessary bootstrapping of new projects, I'll automatically compile
any files in `src/` when the shell starts.

###### Compile initial files.
    case file:list_dir("src") of
        {ok, Initial_files} ->
            lists:foreach(fun (Filename) ->
                            watcherl_compiler ! "src/" ++ Filename
                          end,
                          Initial_files);
        _ -> ok
    end



[Erlang supports shell configuration in a `.erlang` file.]: http://erlang.org/doc/man/erl.html#id179026
[an example of sending a message between processes on the same node]: http://stackoverflow.com/a/16913797/8710
[ERL_LIBS]: http://erlang.org/doc/man/code.html
