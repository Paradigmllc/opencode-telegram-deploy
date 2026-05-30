# opencode-telegram-deploy

Deploy artifacts for the Paradigm OpenCode Telegram Bot. It is designed to run
on Coolify as a Docker Compose application. Source of truth lives in
`Paradigmllc/dotfiles` under `opencode-telegram/`.

This repository is public so Coolify can clone it without GitHub auth. No
secrets are committed here; all credentials come from Coolify environment
variables.

## Paradigm Sales OS bridge

Set these Coolify environment variables to let `@aiparadigmbot` forward sales
instructions to Paradigm Sales OS:

- `SALES_OS_AGENT_WEBHOOK_URL=https://paradigmjp.com/api/sales/agent/telegram-command`
- `SALES_OS_AGENT_WEBHOOK_SECRET` must match the Sales OS webhook secret.

Sales commands stay approval-gated inside Sales OS. The bot forwards intent; it
does not bypass the human gate for live bulk email or form submission.
