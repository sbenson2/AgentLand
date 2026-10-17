# CloudKit schema for notices and the Mac's address

`schema.ckdb` defines the record types of container `iCloud.dev.agentland` and
the indexes AgentLand needs:

- `Notice` (zone `Notices`): push notifications, below.
- `RemoteAccessAddress` (zone `RemoteAccess`): the Mac's address for remote
  access, one record per host named by its `hostId`, every field encrypted
  (`nodeId`, `directAddresses`, `relayUrl`, `revision`, `sequence`;
  docs/HOST-API.md "When the Mac's address changes"). The Mac writes it only
  while "Reach this Mac from anywhere" is on and deletes it when the switch goes
  off; devices fetch it by record ID, so it needs no field index. CloudKit
  creates the type on the Mac's first write in the development environment; the
  schema makes the fields encrypted from the start and is needed for production.

CloudKit creates the `Notice` record type and its fields in the development
environment the first time the Mac writes a notice, but it creates no indexes,
and without them:

- iPhone and iPad cannot save their query subscriptions (`kind` must be
  queryable), so no alert arrives;
- the Mac's hourly cleanup of notices older than 24 hours fails (`hostId` must
  be queryable and `createdAt` sortable). The Mac keeps relaying; Settings →
  Notifications shows the cleanup error.

Apply the schema once per environment. Nothing in the build or the app applies
it.

## With cktool

1. In [CloudKit Console](https://icloud.developer.apple.com), open the
   Settings section of your user account and generate a management token
   (Apple's [Using cktool](https://developer.apple.com/icloud/ck-tool/)). It is
   shown only once.
2. Save it for cktool (it asks for the token and stores it in your login
   keychain):

   ```sh
   xcrun cktool save-token --type management
   ```

3. Check the file against the container, then import it into the development
   environment (cktool imports into development only):

   ```sh
   xcrun cktool validate-schema --team-id 572969HWXM --container-id iCloud.dev.agentland \
     --environment development --file macos/CloudKit/schema.ckdb
   xcrun cktool import-schema --team-id 572969HWXM --container-id iCloud.dev.agentland \
     --environment development --file macos/CloudKit/schema.ckdb
   xcrun cktool export-schema --team-id 572969HWXM --container-id iCloud.dev.agentland \
     --environment development
   ```

   The export should list `Notice` with the indexes below, and
   `RemoteAccessAddress` with its five encrypted fields.

## In CloudKit Console instead

Container `iCloud.dev.agentland` → Development → Schema:

1. Record Types → `Notice` (create it if the Mac has not written one yet) with
   the String fields `alertBody`, `hostId`, `kind`, `projectId`,
   `projectName`, `runId`, `scheduleId`, `sessionId`, `title` and the Date/Time
   field `createdAt`. `runId` and `scheduleId` are unused since schedules were
   removed on 2026-10-06; they stay because a deployed field cannot be deleted.
2. Indexes → `Notice`: add QUERYABLE on `kind`, `hostId` and `recordName`, and
   QUERYABLE and SORTABLE on `createdAt`.
3. Record Types → `RemoteAccessAddress` with the encrypted fields `nodeId`,
   `relayUrl` and `revision` (String), `directAddresses` (String list) and
   `sequence` (Int64), and QUERYABLE on `recordName`.

## Production

Builds signed with the Xcode-managed development profile (the Mac app from
`scripts/build-desktop-app.sh`, the iPhone app from Xcode) use the development
environment. A build signed for distribution (TestFlight, App Store, Developer
ID) uses production: deploy the schema there first with CloudKit Console →
Deploy Schema Changes. Records do not move between environments.
