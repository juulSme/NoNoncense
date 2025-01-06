#!/bin/bash

# Start node 1 in the background, grab its pid.
elixir --name node1@127.0.0.1 --cookie secret -S mix run test/test_conflict_guard.ex &
PID1=$!

sleep 1

# Start node 2 in the background, grab its pid.
elixir --name node2@127.0.0.1 --cookie secret -S mix run test/test_conflict_guard.ex &
PID2=$!

sleep 1

# Have node 1 connect to node 2. Node 1 is older, so node 2 should shut down.
elixir --name node3@127.0.0.1 --cookie secret --rpc-eval node1@127.0.0.1 'Node.connect(:"node2@127.0.0.1")'

# await node 2 exit and store its exit code
wait $PID2
NODE2_EXIT=$?

# gracefully terminate node 1
elixir --name node3@127.0.0.1 --cookie secret --rpc-eval node1@127.0.0.1 ':init.stop(0)'

if [ "$NODE2_EXIT" = "111" ]; then
    echo "Node 2 shut down as expected."
    exit 0
else
    echo "Node 2 did not exit with status 111 as expected."
    exit 1
fi;