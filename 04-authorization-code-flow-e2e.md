# 04 - Authorization Code Flow End-to-End Test

## Objective
Complete a full OIDC Authorization Code grant flow end-to-end against the
IAM Lab Test App — a live browser login and manual token exchange — rather
than relying on Okta's Token Preview simulation.

## Context
Built on `01-oidc-web-app.md` and `02-access-policy-token-verification.md`.
The app, custom `groups` claim, and Access Policy already existed and had
been validated through Token Preview. This entry validates the same
configuration through a real authorization code exchange instead.

## Steps Taken
1. Retrieved the Client ID (`0oa151kmxl3vDLoyz698`) and Client Secret from
   the app's General tab, under Client Credentials
2. Confirmed the registered Sign-in redirect URI:
   `http://localhost:8080/authorization-code/callback`
3. Built and loaded the `/authorize` URL against the org's non-admin
   domain (`integrator-8880746.okta.com`), requesting `openid profile`
   scopes
4. Authenticated in-browser; the browser then tried to redirect to
   `localhost:8080` (no server listening there — expected) with an
   authorization `code` and `state` value visible in the URL
5. Captured the code and exchanged it for tokens via a `curl.exe` POST to
   `/oauth2/default/v1/token`, using `grant_type=authorization_code`

## Issues Encountered & Resolutions

- **Placeholder values submitted literally.** The first exchange attempt
  sent `code=PASTE_CODE_HERE` and `client_secret=YOUR_SECRET_FROM_NOTEPAD`
  unedited into curl. Okta correctly rejected it as `invalid_client`.

- **Truncated client secret.** After swapping in a real code and secret,
  the exchange still failed with `invalid_client — The client secret
  supplied for a confidential client is invalid`. Root cause: the secret
  had been copied by manually highlighting the revealed text in the Okta
  UI, which silently dropped the trailing characters. Re-copying via the
  dedicated clipboard icon next to the secret (instead of manual
  selection) produced the full, correct value.

- **Authorization codes are single-use and short-lived.** Each failed
  exchange attempt burned the code it used, and codes expire in roughly
  60 seconds regardless. A fresh `/authorize` round-trip was required
  before every retry.

- **Transient connection reset.** One retry failed with `curl: (35) Recv
  failure: Connection was reset` — a network-layer failure, not an Okta
  rejection. An immediate, unmodified retry of the same command
  succeeded, confirming it wasn't a configuration issue.

## Verification
The token exchange succeeded, returning `token_type: Bearer`, a valid
`access_token`, an `id_token`, and `scope: openid profile`. Token values
are intentionally omitted from this write-up and were not committed to
the repo — access and ID tokens are bearer credentials and shouldn't be
persisted in plaintext, particularly in version control.

## Key Takeaway
Token Preview and a live Authorization Code flow validate different
things. Token Preview confirms claims and policy are wired correctly;
only a real flow confirms the redirect URI, client authentication, and
code exchange actually work end-to-end for a real client. The most
useful part of this session wasn't the successful exchange itself — it
was tracing *why* the client secret kept failing, which turned out to be
a copy-paste artifact rather than a configuration error.
