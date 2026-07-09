# IAM Lab: OIDC Web App Integration

## Overview
Built a working OpenID Connect (OIDC) Web Application integration in an Okta 
Integrator Free Plan developer org, including a custom group claim on the 
default Authorization Server.

## What I Built

### 1. OIDC Web App
- **App name:** IAM Lab Test App
- **Sign-in method:** OIDC (OpenID Connect)
- **Grant type:** Authorization Code
- **Redirect URIs:** localhost defaults for local testing
- **Client ID:** 0oa151kmxl3vDLoyz698
- **Assignment:** Allow everyone in org, Federation Broker Mode enabled 
  (implicit access controlled by sign-on policy rather than explicit 
  per-user assignment)

### 2. Authentication Policy
- Verified the app enforces "Any two factors" (MFA) by default under 
  the app's Sign On tab.

### 3. Custom Groups Claim
- Added a `groups` claim on the **default Authorization Server**.
- **Value type:** Groups
- **Filter:** Matches regex `.*` (includes all group memberships)
- **Token type:** ID Token, included Always

This means any app using this authorization server now receives the 
user's group memberships inside their ID token, which is the mechanism 
real applications use to make group-based access decisions (e.g. 
restricting an admin panel to a specific group).

## Why OIDC over SAML
OIDC is the modern standard, built on OAuth 2.0, and is Okta's own 
recommendation for new integrations due to better mobile/cloud support 
and simpler configuration compared to SAML's XML-based approach.

## Next Steps
- Create a real test group and assign it to a user to give the groups 
  claim actual data to return
- Test the full authorization code flow end-to-end
- Build a second app using SAML 2.0 to compare configuration differences