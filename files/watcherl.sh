#!/bin/bash
# This file was generated from the README.md.

erlc -o ebin src/*

inotifywait --monitor --event close_write,moved_to --format '%w%f' ebin src | while read file; do
    case $file in
        *.erl)
            erlang_code="{watcherl_compiler, list_to_atom(\"watcherl@\" ++ net_adm:localhost())} ! \"$file\""
            erl -noshell -sname "watcherl_sh_src_$RANDOM" -eval "$erlang_code" -s init stop &
            ;;
        
        *.beam)
            module_name=$(basename "$file" .beam)
            erlang_code="{watcherl_reloader, list_to_atom(\"watcherl@\" ++ net_adm:localhost())} ! \"$module_name\""
        
            erl -noshell -sname "watcherl_sh_beam_$RANDOM" -eval "$erlang_code" -s init stop &
            ;;
    esac
done &

erl -watcherl_on -sname watcherl -pa ebin