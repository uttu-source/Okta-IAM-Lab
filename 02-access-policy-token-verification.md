# 02 - Access Policy & Token Verification

## Objective
Resolve a "Policy evaluation failed" error on Token Preview and verify the
custom `groups` claim renders correctly in an issued ID token.

## Context
Built on `01-oidc-web-app.md`. The IAM Lab Test App and the custom `groups`
claim already existed, but Token Preview failed because the default
Authorization Server had no Access Policy.

## Issue Encountered
Testing Token Preview on the `default` Authorization Server threw
"Policy evaluation failed." Root cause: Okta Authorization Servers require
at least one Access Policy with one Rule before any token can be issued,
regardless of how well the app, scopes, and claims are configured. Claims
and Scopes are independent of Access Policies.

## Steps Taken
1. Navigated to Security > API > default > Access Policies
2. Created a new Access Policy ("IAM Lab Default Access Policy"), scoped to
   IAM Lab Test App specifically rather than "All clients"
3. Added a Rule under the policy ("Default Rule - Auth Code + MFA") allowing
   the Authorization Code grant type, for any user assigned the app, any
   scopes
4. Ran Token Preview: IAM Lab Test App, Authorization Code, self as user,
   scopes openid + profile

## Verification
ID token payload returned successfully with the `groups` claim populated:

\`\`\`json
"groups": ["Everyone", "IAM-Lab-Testers"]
\`\`\`

(Screenshot: 02-token-preview-payload.png)

## Key Takeaway
Scopes and Claims configure *what a token can contain*. Access Policies and
Rules configure *whether a token gets issued at all*. Both are required
independently; a correctly configured claim will silently fail to appear
if the underlying policy layer is missing.