# QA evidence — pt-BR localization

Internal emulator captures for `feature/ptbr-localization`
(`8cfb262704339f5a24580ee78093421eac06c51f`).

This branch is evidence only. It is not a public screenshot set and not a
Play / GitHub Release artifact. The `qa` APK used to take them is not here.

- App: Console QA flavor (`dev.xpetalab.hermesconsole.qa`), profile build
- Device: Android emulator `hermes-qa-api35` (API 35, x86_64, 1080×2400)
- Locale: device `pt-BR`, then Settings → Idioma → Português (Brasil)
- Dataset: fictional Aurora fixture (no real Hermes, no private network)
- Captured: 22 Oct 2026, America/Sao_Paulo

A fixture host that appeared in Settings was covered in
`08_settings_idioma_ptbr.png` so the file does not carry an address.

| File | What it shows |
|---|---|
| `01_welcome_ptbr.png` | First-run welcome |
| `02_help_ptbr.png` | “Ainda não tenho o Hermes” setup |
| `03_manual_connect_ptbr.png` | Manual connect form |
| `04_falta_um_passo_ptbr.png` | Dashboard sign-in still needed |
| `05_nao_deu_certo_ptbr.png` | Unreachable-host error copy |
| `06_home_ptbr.png` | Home board after pairing |
| `07_drawer_ptbr.png` | Navigation drawer |
| `08_settings_idioma_ptbr.png` | Settings → Idioma with Português (Brasil) selected |
| `09_conversas_ptbr.png` | Conversations empty state |
