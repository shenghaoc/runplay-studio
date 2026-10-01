# Decision: Apple Health export archives, not direct HealthKit

**Decision:** support the local Health export archive. Direct HealthKit is not
planned under this project's policy of no paid signing identity, provisioning
profile or restricted entitlement. This is a project constraint, not a claim
that every HealthKit application must have a paid developer account.

## What direct access would need

Apple's [HealthKit Entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit)
directs apps to enable the HealthKit capability to add
`com.apple.developer.healthkit`. [Configuring HealthKit access](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)
says that enabling it links the framework, updates the entitlement and, with
automatic signing, enables HealthKit for the app's App ID.

[Adding capabilities to your app](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app)
describes team configuration, provisioning assets and capability availability
by platform and membership. Merely linking a framework from a SwiftPM target
is not the capability/signing configuration Apple describes. Apple's
[restricted-entitlement signing guide](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
explains that a restricted entitlement requires authorization by a
provisioning profile; an entitlement string alone is not that authorization.
This general rule does not itself prove a HealthKit-specific paid-membership
requirement.

## Membership finding

Apple's [developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
puts portal access to Certificates, Identifiers & Profiles among program-member
resources, but also describes free Personal Team provisioning managed by Xcode.
More specifically, the current [supported iOS capabilities table](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
marks HealthKit available to **ADP, ADEP and free Apple Developer** accounts.
That table identifies ADP/ADEP as paid programs and Apple Developer as free.
Consequently, the proposed universal paid-membership requirement is **not
established by the current documentation** and must not be asserted here.

Apple's [HealthKit framework reference](https://developer.apple.com/documentation/healthkit) lists macOS, while Configuring HealthKit access describes the capability as available for iOS and watchOS; that availability contradiction does not change this project's signing-policy decision.

## Consequence

RunPlay Studio deliberately supplies no HealthKit entitlement or provisioning
profile. The project therefore does not pursue the capability-backed direct
access path, regardless of membership eligibility or the unresolved native
macOS availability discrepancy. There is no permission-flow, route-sync or
Developer ID experiment in this decision.

The supported path is **Import Apple Health Export…**: read a user-selected
archive locally, review running-workout candidates, and persist only selected
runs and their supported route/HR data. See [the import guide](apple-health-import.md)
and [privacy policy](privacy.md#apple-health-export-import). The unused,
non-functional HealthKit importer is removed rather than presented as support.
