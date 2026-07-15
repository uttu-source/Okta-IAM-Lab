# 03 - SAML 2.0 App & OIDC Comparison

## Objective
Build a SAML 2.0 app integration in Okta alongside the existing OIDC app,
and document the practical differences between the two protocols from an
IdP-configuration standpoint.

## Context
Okta supports two major federation protocols for Single Sign-On (SSO):
OIDC (OpenID Connect) and SAML (Security Assertion Markup Language). Both
let Okta act as an Identity Provider (IdP) that vouches for a user to a
Service Provider (SP), but they use different formats and setup flows.

## Steps Taken
1. Added a generic **SAML Service Provider** app from Okta's catalog
   (no real SP was available, so this is a dummy/test integration used
   to document the IdP-side configuration process)
2. Configured a **Group Attribute Statement** to mirror the OIDC `groups`
   claim: Name `groups`, Filter "Matches regex", Value `.*`
3. Entered placeholder values for Assertion Consumer Service URL and
   Service Provider Entity ID, since no real SP existed to supply these
4. Used **Preview SAML** to inspect the raw XML assertion Okta would
   generate
5. Assigned myself to the app

## Key Differences Observed: OIDC vs SAML

| Aspect | OIDC | SAML |
|---|---|---|
| Data format | Compact JSON token | Verbose XML assertion |
| Group data | Custom `groups` claim | Group Attribute