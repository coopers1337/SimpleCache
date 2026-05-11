--!strict

type Node = {
	key:       string,
	value:     any,
	expiresAt: number,
	prev:      Node?,
	next:      Node?,
}

export type Stats = {
	hits:      number,
	misses:    number,
	evictions: number,
	size:      number,
}

export type Options = {
	maxSize:  number?,
	ttl:      number?,
	onEvict:  ((key: string, value: any) -> ())?,
}

export type Cache = {
	get:      (self: Cache, key: string) -> any,
	set:      (self: Cache, key: string, value: any, ttl: number?) -> (),
	has:      (self: Cache, key: string) -> boolean,
	peek:     (self: Cache, key: string) -> any,
	delete:   (self: Cache, key: string) -> boolean,
	clear:    (self: Cache) -> (),
	size:     (self: Cache) -> number,
	getOrSet: (self: Cache, key: string, fn: () -> any, ttl: number?) -> any,
	prune:    (self: Cache) -> number,
	keys:     (self: Cache) -> { string },
	values:   (self: Cache) -> { any },
	stats:    (self: Cache) -> Stats,
}

type CacheImpl = Cache & {
	_map:        { [string]: Node },
	_head:       Node,
	_tail:       Node,
	_count:      number,
	_maxSize:    number,
	_defaultTTL: number,
	_onEvict:    ((string, any) -> ())?,
	_hits:       number,
	_misses:     number,
	_evictions:  number,
}

local Cache = {}
Cache.__index = Cache

local function detach(node: Node)
	if node.prev then node.prev.next = node.next end
	if node.next then node.next.prev = node.prev end
	node.prev = nil
	node.next = nil
end

local function insertAfterHead(self: CacheImpl, node: Node)
	node.prev = self._head
	node.next = self._head.next
	if self._head.next then self._head.next.prev = node end
	self._head.next = node
end

local function promoteToHead(self: CacheImpl, node: Node)
	if node.prev == self._head then return end
	detach(node)
	insertAfterHead(self, node)
end

local function popLRU(self: CacheImpl): Node?
	local lru = self._tail.prev
	if lru == self._head then return nil end
	detach(lru :: Node)
	return lru
end

local clock = os.clock

local function expired(node: Node): boolean
	return node.expiresAt ~= 0 and clock() > node.expiresAt
end

local function evict(self: CacheImpl, node: Node)
	self._map[node.key] = nil
	detach(node)
	self._count     -= 1
	self._evictions += 1
	if self._onEvict then self._onEvict(node.key, node.value) end
end

local function makeExpiry(self: CacheImpl, ttl: number?): number
	local t = ttl or self._defaultTTL
	return t == 0 and 0 or clock() + t
end

function Cache.new(opts: Options?): Cache
	local o    = opts or {}
	local head: Node = { key = "", value = nil, expiresAt = 0 }
	local tail: Node = { key = "", value = nil, expiresAt = 0 }
	head.next  = tail
	tail.prev  = head

	return setmetatable({
		_map        = {},
		_head       = head,
		_tail       = tail,
		_count      = 0,
		_maxSize    = o.maxSize    or math.huge,
		_defaultTTL = o.ttl        or 0,
		_onEvict    = o.onEvict,
		_hits       = 0,
		_misses     = 0,
		_evictions  = 0,
	}, Cache) :: any
end

function Cache:get(key: string): any
	local self = self :: CacheImpl
	local node = self._map[key]

	if not node then
		self._misses += 1
		return nil
	end
	if expired(node) then
		evict(self, node)
		self._misses += 1
		return nil
	end

	promoteToHead(self, node)
	self._hits += 1
	return node.value
end

function Cache:set(key: string, value: any, ttl: number?)
	local self = self :: CacheImpl
	local node = self._map[key]

	if node then

		node.value     = value
		node.expiresAt = makeExpiry(self, ttl)
		promoteToHead(self, node)
		return
	end

	while self._count >= self._maxSize do
		local lru = popLRU(self)
		if not lru then break end
		self._map[lru.key] = nil
		self._count     -= 1
		self._evictions += 1
		if self._onEvict then self._onEvict(lru.key, lru.value) end
	end

	local new: Node = {
		key       = key,
		value     = value,
		expiresAt = makeExpiry(self, ttl),
	}
	insertAfterHead(self, new)
	self._map[key] = new
	self._count   += 1
end

function Cache:has(key: string): boolean
	local self = self :: CacheImpl
	local node = self._map[key]
	if not node then return false end
	if expired(node) then evict(self, node); return false end
	return true
end

function Cache:peek(key: string): any
	local self = self :: CacheImpl
	local node = self._map[key]
	if not node then return nil end
	if expired(node) then evict(self, node); return nil end
	return node.value
end

function Cache:delete(key: string): boolean
	local self = self :: CacheImpl
	local node = self._map[key]
	if not node then return false end
	evict(self, node)
	return true
end

function Cache:clear()
	local self = self :: CacheImpl
	if self._onEvict then
		for _, node in self._map do
			self._onEvict(node.key, node.value)
		end
	end
	table.clear(self._map)
	self._head.next = self._tail
	self._tail.prev = self._head
	self._count     = 0
end

function Cache:size(): number
	return (self :: CacheImpl)._count
end

function Cache:getOrSet(key: string, fn: () -> any, ttl: number?): any
	local v = self:get(key)
	if v ~= nil then return v end
	v = fn()
	self:set(key, v, ttl)
	return v
end

function Cache:prune(): number
	local self   = self :: CacheImpl
	local now    = clock()
	local pruned = 0

	for _, node in self._map do
		if node.expiresAt ~= 0 and now > node.expiresAt then
			evict(self, node)
			pruned += 1
		end
	end
	return pruned
end

function Cache:keys(): { string }
	local self = self :: CacheImpl
	local now  = clock()
	local out  = {}
	for key, node in self._map do
		if node.expiresAt == 0 or now <= node.expiresAt then
			table.insert(out, key)
		end
	end
	return out
end

function Cache:values(): { any }
	local self = self :: CacheImpl
	local now  = clock()
	local out  = {}
	for _, node in self._map do
		if node.expiresAt == 0 or now <= node.expiresAt then
			table.insert(out, node.value)
		end
	end
	return out
end

function Cache:stats(): Stats
	local self = self :: CacheImpl
	return {
		hits      = self._hits,
		misses    = self._misses,
		evictions = self._evictions,
		size      = self._count,
	}
end

return Cache
