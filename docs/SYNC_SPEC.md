# Oxplayer App Library and Sink Specification (Flutter Android)

This document documents the **product intent and target architecture** to align current and future implementations. The next parts of the flow (server details, playback, …) will be completed later in this repo.

**Initial Catalog Entry (Create `Media` / `MediaFile` and Replay with `MediaFileID`):** [`backend/captioner-bot/CAPTIONER_FLOW.md`](../../backend/captioner-bot/CAPTIONER_FLOW.md)

---

## 1. Authenticate and connect to server

| Step | Explanation                                                                                                                            |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | User logs in with **Telegram** (TDLib).                                                                                                |
| 2    | With the **`Oxplayer API`** the project itself verifies the identity to the **dedicated server** (e.g. JWT after `initData` / WebApp). |

---

## 2. Access requirements (before meaningful sink)

Before the sink or library can be relied upon, we need to make sure we have **access** to the following (channel membership, private chat with bot, etc. — according to Telegram and TDLib rules):

| Variable / Concept          | Role                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------ |
| `REQUIRED_CHANNEL_USERNAME` | Required channel(s) that the user must be a member of.                               |
| `PROVIDER_BOT_USERNAME`     | Provider bot (if used during retrieval).                                             |
| `BOT_USERNAME`              | The main bot associated with the index / WebApp (same as the current project logic). |

If none of these accesses are available, the app's behavior should be transparently reported to the user (this document only documents the requirement; the UI text is separate).

---

## 3. Sync execution time

| Library state from server | Target behavior                                                |
| ------------------------- | -------------------------------------------------------------- |
| **Empty list**            | **Automatic** sync once (or according to later product rules). |
| **Non-empty list**        | **Manual** sync only (explicit user button/action).            |

Goal: Avoid overload when user already has content, while also initializing for new user.

---

## 4. Telegram "Discovery" goal logic (sync)

This part is **what we want the code to achieve**; it may not be the same as the current implementation.

### 4.1 Time starting point

- If the server has given the client a valid **Last date/Watermark**, the search can be limited from that point onwards (API contract details will be finalized later with the server).
- If **empty** (no date from server): No date filter, only search by **`INDEX_TAG`** (a **configuration fixed** hashtag).

### 4.2 Where do we search?

- **Current implementation:** TDLib **`searchMessages`** with `chat_list = null` — search in **all non-secret chats** that are in the supported Main/Archive lists (without manual looping on each `chatId`).

- Order of results according to TDLib: **newest to oldest** (reverse chronological).

- Only messages with a valid **`MediaFileID:`** in the text/caption (+ `telegramFileId` for sending to the server) are kept.

### 4.2.1 Incremental watermark (Telegram load reduction)

- If the server library is **not empty**, `GET /me/library` returns the **`lastIndexedAt`** value: `max(user_access.granted_at)` for that user.
- The app also stores that moment in **`SharedPreferences`** and passes **`max(server lastIndexedAt, local value)`** as **`min_date`** to `searchMessages` for the next sync, so that messages older than that moment are filtered from the Telegram server.
- **Note:** `min_date` in TDLib is based on **`Message.date`** (Telegram message time) and not exactly the same database timestamp; for newly indexed posts it usually matches `granted_at`. If the "newly indexed old Telegram message" scenario becomes important, the watermark can be separated based on the `max(telegramDate)` of the last sink.

### 4.3 Size and order of results

| Parameter  | Target value                                          |
| ---------- | ----------------------------------------------------- |
| Result cap | Max ~500\*\* items (adjustable; can be less).         |
| Order      | Always **newer to older** (prioritize newer content). |

### 4.4 Remove "send to server every 10 seconds" logic

- Currently or previously we sent results to the server **in batches every ~10 seconds** to reduce complexity.
- **Goal:** Remove this layer; make the flow **more transparent**:

1. Search continues until the cap or end of results is reached.
2. Create a **final list of objects** (each `mediaFileId` + locator; section 4.5).
3. **Once** (or a limited number of large requests, not a hidden timer) sent to the server.

### 4.5 Discovery Phase Output

After the search is complete, we should have an **object** for **each** message associated with the index, not just a string.

**Yes — just `MediaFileID` is not enough.** We have already concluded that for subsequent playback/retrieval, the server should also know the **exact location of the file in Telegram** so that it can fill in the **`UserFileLocator`** record (or its equivalent in the pipeline): the difference between a private chat with a person, a bot, a group, a channel, and a Saved Messages storage, plus the message/file coordinates.

#### 4.5.1 Target fields of each item (in line with `UserFileLocator`)

In the database, the `user_file_locators` table (Prisma model: **`UserFileLocator`**) contains these concepts; The sink payload should provide the minimum information required for **upsert** of this model for each media:

| Concept in product                                        | Role                                                                                                                                                                                             |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mediaFileId`                                             | Media UUID from caption (`MediaFileID:`) or pseudo-contract if technically required.                                                                                                             |
| **Conversation location type**                            | For human/log: private / bot / group / channel / Saved Messages — inferred from TDLib chat type.                                                                                                 |
| `locatorType`                                             | Server-side enum value; in the scenario "message in a chat with known `chatId` and `messageId`" usually **`CHAT_MESSAGE`**. In other scenarios it may later be **`BOT_PRIVATE_RUNTIME`** or \*\* |
| `REMOTE_FILE_ID`\*\* is used (according to API contract). |
| `chatId`                                                  | TDLib chat ID (big number). For Saved Messages it is the same as the ``saved messages'' chat.                                                                                                    |
| `messageId`                                               | Message ID inside that chat.                                                                                                                                                                     |
| `remoteFileId`                                            | Remote Telegram file ID (`telegramFileId` / unique file id) if needed for download or matching with `media_files.file_unique_id`.                                                                |
| `botUsername`                                             | If associated with a specific bot (optional, depending on locator type).                                                                                                                         |

The output of the discovery step is then an **array of objects**, not an empty `string[]`.

#### 4.5.2 Pseudo IDs

**Current Implementation Status (MVP):** The client only gets messages that have a **`MediaFileID:`** with a valid UUID in the text (captioner output). The pseudo-path has been removed to keep the sink simple; it will be added back later if needed.

---

## 5. Sending to the server and response (summary)

- The client sends to the **`Oxplayer API`** a **list of objects**; each element has at least a **`mediaFileId`** along with **locator fields** (as per section 4.5.1).
- In addition, there may be other auxiliary fields (e.g. `captionText` for ingest metadata) in the same object or in the request body — the final field naming convention will be fixed in the OpenAPI / API version.
- The **server-side processing** is described step-by-step in **section 8**; the **final response to the user** is the same structure built from **`UserAccess`** (along with **`Media`**, **`MediaFile`**, **`UserFileLocator`**).

---

## 8. Server logic after receiving the sink list

This is the **target contract** for the `Oxplayer API`: after the client sends an array of objects (each with `mediaFileId` + locator, etc.).

### 8.1 General principle: the main `container` is `Media` and `MediaFile`

- The source of truth for the catalog content is the **`media`** and **`media_files`** tables.
- **`UserAccess`** holds the link ``This user has permission to view this `MediaFile`` (along with `sourceId` in the current model).
- **`UserFileLocator`** specifies **where in Telegram** the file should be retrieved (chat, message, `remoteFileId`, etc.).

Sink means: for items that the user has access to in Telegram and we **already have the corresponding media in the DB**, fix and update these two links.

### 8.2 Step 1 — Is it already "mapped" for this user?

For each `mediaFileId` (and the same locator if needed) the database checks:

- Does the current **`userId`** have a record in **`UserAccess`** with this **`mediaFileId`** **and**
- Is the corresponding record in **`UserFileLocator`** (the same user-file pair) sufficiently complete/valid?

| Status       | Meaning Goal                                                                                                                                                                                              |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mapped**   | No additional work is needed on this item in this request (or just update the locator if the message location changes — product decision).                                                                |
| **Unmapped** | It should be **handled** in the next steps: either it goes to the `needs to link` list, or to side paths (e.g. ingest, provider, error to client) — depending on whether `MediaFile` is in the DB or not. |

### 8.3 Step 2 — Does `mediaFileId` exist in the database at all?

- Any ID that **doesn't exist** in the **media_files`** table (PK is `id`) is removed from the **process list for this step** (or reported as `unknown/ignored` in the response — strict API response convention).

> **Implementation Note:** If the product has the **ingest from client payload** path enabled, the `MediaFile` row may be created _before_ this filter; in that case the order of steps in the code with this document should be explicit. In the **mental model of the document**, "removal from list" means: without a `MediaFile` row, the `UserAccess` link is not created in this pipeline.

### 8.4 Step 3 — Linking for valid remnants

Items that:

1. exist in **`media_files`**, and
2. are not yet properly linked to our library for this user (according to step 1),

i.e.: the user has access to that file in Telegram but we did not previously have a complete **`UserAccess`** / **`UserFileLocator`** for him.

For each:

- **upsert** **`UserAccess`** for `(userId, mediaFileId)` with the appropriate **`sourceId`** (e.g. from `chatId` → **`source`** table).
- **`UserFileLocator`** is **upsert** from the locator data sent by the client for the same `(userId, mediaFileId)`.

Thus **the same existing `Media` and `MediaFile`** are connected to the user and to the Telegram coordinates; again **new `Media` / `MediaFile`** is created only when the ingest / captioner path has added a separate one — not as the "main container" of this step.

### 8.5 Reply to the client (library display)

To reply to the user after applying the sink (and usually for **`GET /me/library`** as well):

- From **`UserAccess`**, the current **`userId`** is queried.
- join / include on:
- **`MediaFile`** (and from it **`Media`**),
- **`UserFileLocator`** (for the same user and the same file),
- if necessary **`Source`** etc. according to the current API DTO.

The output is a **list of objects** (or the current `items[]` aggregate structure of the project) that the app can display **list of movies/series and files and playback location**.

---

## 9. Open questions (to be finalized in the implementation)

1. **Exact definition of "mapped":** Is it enough to have only `UserAccess` without `UserFileLocator` or are both required? If the locator is incomplete, do we consider it as `needing to update'?
2. **Identifiers removed from the list (without `MediaFile` in the DB):** Should `unknownMediaFileIds` / `igno` be explicitly specified in the sync response body?
   redIds` to return the appropriate client log or UI?
3. **Ordering relative to ingest:** Should the ingest from the client always be executed **before** step 2 or only for a subset of items?

Update this section in the same PR after the decision.

---

## 6. Implementation status

- Current code may differ from this document in **chats navigation, preferences, batch every 10 seconds, and sending refs**.

- Any changes to `oxplayer-android` and `Oxplayer API` should update this document or reference it in the PR.

---

## 7. Document continuation

The following sections (JSON contract details, date watermark, playback, provider, error codes) will be added to this repository as described separately. The sync server logic is documented in **Section 8** and open questions in **Section 9**.
