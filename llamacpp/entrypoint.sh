#!/bin/bash
# /zeno/llamacpp/entrypoint.sh

# This script is the entrypoint for llama.cpp container
# It simply forwards all arguments to the llama binary

exec /zeno/llamacpp/build/bin/llama "$@"