# cache.luau

Fast LRU + TTL cache for Roblox. Zero dependencies, ~200 lines, `--!strict`.  
O(1) get / set / delete — hash map + doubly-linked list under the hood.

## Install

Drop `cache.luau` into a `ModuleScript` (e.g. `ReplicatedStorage.Cache`) and require it:

```luau
local Cache = require(game.ReplicatedStorage.Cache)
```

---

## Quick start

```luau
local c = Cache.new({
    maxSize = 500,  -- evicts LRU entry when full        (default: unlimited)
    ttl     = 60,   -- seconds before entries expire     (default: forever)
})

c:set("coins", 250)
c:get("coins")   --> 250

c:set("badge", true, 10)  -- overrides default TTL, expires in 10s
c:get("badge")            --> true  (or nil after 10 seconds)
```

---

## API

### `Cache.new(opts?)`

Creates a new cache. All options are optional.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `maxSize` | `number` | `∞` | Max entries. Oldest (LRU) entry is dropped when full. |
| `ttl` | `number` | `0` (forever) | Default expiry in seconds for all entries. |
| `onEvict` | `(key, value) -> ()` | `nil` | Called whenever an entry is removed for any reason. |

---

### Core

#### `cache:set(key, value, ttl?)`
Store a value. Optional `ttl` overrides the cache default for this entry only.
```luau
c:set("health", 100)
c:set("session", data, 300)  -- expires in 5 min
```

#### `cache:get(key) → value?`
Retrieve a value. Returns `nil` if missing or expired. Promotes the entry to most-recently-used.
```luau
local hp = c:get("health")  -- 100, or nil
```

#### `cache:has(key) → boolean`
Check if a key exists and is not expired. Does **not** count as a hit or promote to MRU.
```luau
if c:has("session") then ... end
```

#### `cache:delete(key) → boolean`
Remove a key. Returns `true` if it existed.
```luau
c:delete("session")  --> true
```

#### `cache:clear()`
Wipe the entire cache. Fires `onEvict` for every entry if set.

---

### Helpers

#### `cache:getOrSet(key, fn, ttl?) → value`
The pattern you'll use most. Returns the cached value, or calls `fn()`, stores the result, and returns it. Avoids double-lookups.
```luau
-- DataStore only called on a cache miss
local data = playerCache:getOrSet(userId, function()
    return DataStoreService
        :GetDataStore("Players")
        :GetAsync(userId)
end, 300)
```

#### `cache:peek(key) → value?`
Read a value without promoting it to MRU or counting a hit/miss. Good for debugging.

#### `cache:prune() → number`
Sweep and remove all expired entries. Returns the count removed. Call this periodically on a Heartbeat timer if you use TTLs and have a large cache.
```luau
local RunService = game:GetService("RunService")
local elapsed = 0

RunService.Heartbeat:Connect(function(dt)
    elapsed += dt
    if elapsed >= 30 then
        elapsed = 0
        c:prune()
    end
end)
```

---

### Introspection

#### `cache:size() → number`
Number of entries currently in the cache (includes unexpired entries only).

#### `cache:keys() → {string}`
All live keys as an array (unordered).

#### `cache:values() → {any}`
All live values as an array (unordered).

#### `cache:stats() → Stats`
Snapshot of cache performance.
```luau
print(c:stats())
-- { hits = 482, misses = 31, evictions = 10, size = 87 }
```

---

## Roblox patterns

### Server-side singleton
Require the same `ModuleScript` from multiple scripts — Roblox caches the result of `require()`, so you always get the same instance:

```luau
-- CacheStore.luau (ModuleScript)
local Cache = require(script.Parent.Cache)
return Cache.new({ maxSize = 1000, ttl = 120 })

-- Anywhere on the server:
local store = require(game.ServerScriptService.CacheStore)
store:set("foo", "bar")
```

### DataStore write-through
```luau
local DS = DataStoreService:GetDataStore("Players")

local function savePlayer(userId, data)
    playerCache:set(userId, data, 300)
    DS:SetAsync(userId, data)
end

local function loadPlayer(userId)
    return playerCache:getOrSet(userId, function()
        return DS:GetAsync(userId)
    end, 300)
end
```

### Eviction logging
```luau
local c = Cache.new({
    maxSize = 100,
    onEvict = function(key, value)
        print("[cache] evicted", key)
    end,
})
```

---

## How it works

- **Hash map** (`_map`) for O(1) key lookup.
- **Doubly-linked list** with two sentinel nodes (`_head` / `_tail`) for O(1) LRU promotion and eviction with zero nil edge-cases.
- **Lazy expiry** — expired entries are removed on access (`get`, `has`, `peek`). Call `prune()` to sweep proactively.
- `expiresAt = 0` means immortal — one branch, no special-casing anywhere.
