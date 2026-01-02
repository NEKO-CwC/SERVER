#!/bin/bash

# 添加 Github Key
if command -v git &> /dev/null; then
    git clone git@github.com:username/private-repo.git
fi

