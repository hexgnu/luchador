local sha1 = require "luchador.sha1"
local serializer = require "luchador.serializer"
local zlib = require "zlib"

local Storage = {}
local mt = {__index = Storage}

function Storage.new(datastore)
  local storage = {datastore = datastore}
  setmetatable(storage, mt)
  return storage
end

function Storage:page_key()
  local homescreen_sig = self.datastore:get("live_homescreens_signature", false)
  if homescreen_sig == nil then
    homescreen_sig = ""
  end

  local path = string.gsub(ngx.var.request_uri, "?.*", "")
  local key = ngx.var.scheme .. "://" .. ngx.var.host .. path .. homescreen_sig
  return sha1.hexdigest(key)
end

function Storage:get_metadata(req_h)
  local metadata = self:get(self:page_key())

  if metadata == nil then
    return nil
  else
    ngx.log(ngx.INFO, "HIT")
    for _, metadata in pairs(metadata) do
      local cached_vary_key = metadata[1]
      local cached_req_h = metadata[2]
      local cached_resp_h = metadata[3]

      if cached_resp_h['Vary'] then
        if cached_vary_key == self.vary_key(cached_resp_h['Vary'], req_h) then
          return cached_resp_h
        end
      else
        return cached_resp_h
      end
    end
  end
end

function Storage:store_metadata(req_h, resp_h, digest_key, ttl)
  if resp_h["Date"] == nil then
    resp_h["Date"] = ngx.http_time(ngx.time())
  end

  resp_h['X-Content-Digest'] = digest_key
  resp_h['Set-Cookie'] = nil
  local k = self:page_key()
  local h = (self:get(k) or {})

  local vk = self.vary_key(resp_h['Vary'], req_h)
  local vary_position = 1
  for i,v in ipairs(h) do
    if v[1] == vk then
      vary_position = i
    else
      vary_position = i + 1
    end
  end

  local cached_vary_val = {vk, req_h, resp_h}
  h[vary_position] = cached_vary_val

  self:set(k, h, ttl)
end

function Storage.vary_key(vary, req_h)
  local vk = {}

  if vary then
    for h in vary:gmatch("[^ ,]+") do
      h = h:lower()
      table.insert(vk, req_h[h] or '')
    end
  end

  return table.concat(vk)
end

function Storage:get_page(metadata)
  if not (metadata == nil) then
    local digest = metadata["X-Content-Digest"]
    if not (digest == nil) then
      return self:get(digest, false)
    end
  end
end

function Storage:store_page(resp, req_h)
  if not (resp.status == 200) then -- TODO cache all response codes rack cache does
    return false
  end

  local ttl = resp:ttl()
  if ttl == nil or ttl == '0' then return false end

  ngx.log(ngx.INFO, "MISS" .. ngx.var.request_uri)

  local digest_key = ngx.md5(resp.body)

  local h = resp.header['Content-Type']
  if h:match('text') or h:match('application') then
    resp.body = zlib.compress(resp.body, zlib.BEST_COMPRESSION, nil, 15+16)
    resp.header["Content-Encoding"] = "gzip"
  else
    resp.header['Content-Encoding'] = nil
  end

  self:store_metadata(req_h, resp.header, digest_key, ttl)
  self:set(digest_key, resp.body, ttl)
  return true
end

function Storage:get_lock()
  local r, err = ngx.shared.cache:add(self:page_key() .. 'lock', true, 15)
  return r
end

function Storage:release_lock()
  return ngx.shared.cache:delete(self:page_key() .. 'lock')
end

function Storage:set(key, val, ttl)
  val = {val = val, ttl = ttl, created = ngx.time()}
  val = serializer.serialize(val)
  ngx.shared.cache:set(key, self.datastore:set(key, val, ttl), ttl)
  ngx.shared.cache:flush_expired(5)
end

function Storage:get(key)
  local locally_cached = false
  local entry = ngx.shared.cache:get(key)
  if entry then
    locally_cached = true
  else
    entry = self.datastore:get(key)
  end

  local thawed
  if entry then
    thawed = serializer.deserialize(entry)
  end

  if thawed then
    if not locally_cached then
      local age = (ngx.time() - thawed.created)
      ngx.shared.cache:set(key, entry, thawed.ttl - age)
    end

    return thawed.val
  end
end

function Storage:keepalive()
  self.datastore:keepalive()
end

return Storage