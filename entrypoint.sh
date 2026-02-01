#!/bin/bash
set -e

# GitHub 인증 설정 (GH 토큰이 있을 경우에만)
if gh auth status &>/dev/null; then
    gh auth setup-git
    git config --global user.name "$(gh api user | jq -r .login)"
    git config --global user.email "$(gh api user/emails | jq -r '[.[] | select(.visibility != "private")][0].email')"
fi

# 원래 명령 실행
exec "$@"
