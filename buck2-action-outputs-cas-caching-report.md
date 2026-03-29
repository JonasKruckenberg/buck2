# Buck2: Action Outputs, CAS & Caching Architecture

## 1. Action Outputs

**Declaration → Execution → Materialization**

Rules declare outputs via `ctx.actions.declare_output()` in Starlark. These are abstract artifacts — they don't exist on disk yet. When passed to `ctx.actions.run()` via `.as_output()`, they become bound to an action. Buck2 only executes actions whose outputs are actually needed downstream (bottom-up evaluation).

**Key types:**

| Type | Location |
|------|----------|
| `ActionKey` | `app/buck2_artifact/src/actions/key.rs` |
| `ActionOutputs` | `app/buck2_build_api/src/actions/` |
| `ArtifactValue` | `app/buck2_execute/src/artifact_value.rs` |
| `ActionDirectoryMember` | `app/buck2_execute/src/directory.rs` |

An `ArtifactValue` stores either a file digest + is_executable flag, a full directory tree of digests, or a symlink target.

## 2. Content Addressable Storage (CAS)

CAS is how Buck2 identifies all content — files, directories, and actions — by cryptographic hash.

**Core digest types** (`app/buck2_common/src/cas_digest.rs`):

- `CasDigest<Kind>` — generic digest parameterized by a marker type
- `FileDigest = CasDigest<FileDigestKind>` — for file contents
- `ActionDigest = CasDigest<ActionDigestKind>` — for action commands (defined in `app/buck2_execute/src/execute/action_digest.rs`)
- `TrackedCasDigest<Kind>` — wraps a digest with additional metadata

**Supported algorithms:** SHA1, SHA256, Blake3, Blake3Keyed (configured via `DigestConfig` in `app/buck2_execute/src/digest_config.rs`).

**CAS is remote** — Buck2 uses the Bazel Remote Execution API's CAS. Configured via `cas_address` in `.buckconfig`. The RE client (`app/buck2_execute/src/re/client.rs`) handles:

- Uploading inputs missing from RE CAS before remote execution
- Downloading outputs from CAS when materializing
- TTL tracking to detect expired artifacts

**Key CAS operations:**

- `Uploader::find_missing()` — query which digests RE doesn't have
- `re_client.materialize_files()` — download files by digest
- `re_client.write_action_result()` — upload action results

## 3. Caching — Three Layers

### Layer 1: DICE (in-memory, within a daemon session)

DICE (Deterministic Incremental Computation Engine, in `dice/`) is Buck2's core incrementality engine. Every computation — parsing, configuration, analysis, action execution — is a DICE key.

- `BuildKey` (wraps `ActionKey`) is the DICE key for action execution (`app/buck2_build_api/src/actions/calculation.rs`)
- On file change, DICE invalidates affected keys and recomputes only what's needed
- Only successful results are cached; errors are always recomputed
- Persists across builds within one daemon session

### Layer 2: Remote Action Cache (across builds and machines)

Before executing any action, Buck2 queries a remote action cache:

1. Compute `ActionDigest` from the action's command + all input digests
2. Query RE action cache (`re_client.action_cache(digest)`) — see `app/buck2_execute_impl/src/executors/action_cache.rs`
3. **Hit**: download outputs from CAS, skip execution
4. **Miss**: execute the action, then upload results via `CacheUploader` (`app/buck2_execute_impl/src/executors/caching.rs`)

Configured via `action_cache_address` in `.buckconfig`.

### Layer 3: Dep File Cache (fine-grained incremental)

For actions that produce dependency files (like C++ `.d` files), Buck2 can do finer-grained caching:

- `app/buck2_action_impl/src/actions/impls/run/dep_files.rs`
- Instead of hashing *all* inputs, it hashes only the inputs the action actually read (as reported by the dep file)
- Enables cache hits even when irrelevant inputs change
- Works both locally and as a remote dep file cache

### Execution Flow

```
DICE BuildKey.compute()
  │
  ├─ [DICE cache hit?] → return cached ActionOutputs
  │
  ├─ Prepare action → compute ActionDigest
  │
  ├─ Query remote action cache
  │   ├─ Hit → download outputs → return
  │   └─ Miss ↓
  │
  ├─ Query remote dep file cache
  │   ├─ Hit → download outputs → return
  │   └─ Miss ↓
  │
  ├─ Execute (local or remote)
  │
  ├─ Upload results to action cache
  │
  └─ Return ActionOutputs to DICE
```

## 4. Materialization

The **Materializer** (`app/buck2_execute/src/materialize/materializer.rs`) controls when and how outputs actually appear on disk in `buck-out/`.

**Two modes:**

- **Deferred (default, recommended):** `DeferredMaterializerAccessor` in `app/buck2_execute_impl/src/materializers/deferred.rs`. Outputs stay as CAS references until something actually needs them on disk. Provides ~2.5x speedup at Meta.
- **Immediate:** Downloads everything right after execution.

### Deferred Materializer Architecture

- Single background command-processing thread serializes all metadata operations
- An in-memory `ArtifactTree` (prefix trie) tracks every artifact's state: `Declared` (known but not on disk) or `Materialized` (on disk)
- `ensure_materialized()` triggers actual downloads via the `IoHandler` trait
- A **SQLite database** (`app/buck2_execute_impl/src/sqlite/materializer_db.rs`) persists artifact metadata across daemon restarts
- TTL refresh keeps CAS artifacts alive for deferred access

### Materialization Methods

How an artifact actually gets onto disk:

1. **CasDownload** — fetch from RE CAS
2. **LocalCopy** — copy from another local artifact
3. **Write** — generate content inline (zstd-compressed)
4. **HttpDownload** — fetch via HTTP URL

## Summary

Buck2 computes a content hash (digest) for every action and its inputs, checks a remote action cache before executing, uses DICE for in-process incrementality, and defers actually downloading outputs to disk until they're needed — all built on a remote CAS that stores content by hash.
