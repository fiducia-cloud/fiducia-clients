% Fiducia HTTP client (MATLAB). Zero-dependency -- matlab.net.http + jsonencode/jsondecode (built-in).
% Implements PROTOCOL.md.
%
%   c = Fiducia('https://api.fiducia.cloud');
%   lk = c.lockAcquire('orders/checkout', 'ttl_ms', 30000);
%   c.lockRelease('orders/checkout', 'worker-a', lk.result.output.fencing_token);
%
% Every method returns the decoded JSON response (a struct/cell/array via
% jsondecode; [] for an empty body). On HTTP status >= 300 it raises an
% MException with identifier 'fiducia:httpError' whose message carries the
% numeric status and the raw response body. Requires MATLAB R2019b or newer
% (arguments blocks). Name-value options use MATLAB's name-value syntax, e.g.
% c.lockAcquire('k', 'ttl_ms', 30000) or, on R2021a+, c.lockAcquire('k', ttl_ms=30000).

classdef Fiducia < handle
    % Fiducia  Thin HTTP client for the fiducia.cloud coordination API.

    properties
        BaseUrl            % Base URL, trailing slash trimmed.
        RequestTimeout = 30  % Request timeout in seconds (connect + response). Set [] to use the matlab.net.http default.
    end

    methods
        function obj = Fiducia(baseUrl)
            arguments
                baseUrl (1,:) char
            end
            obj.BaseUrl = regexprep(baseUrl, '/+$', '');
        end

        % --- misc ---
        function out = health(obj)
            out = obj.doRequest('GET', '/healthz');
        end

        function out = status(obj)
            out = obj.doRequest('GET', '/v1/status');
        end

        % --- locks ---
        function out = lockGet(obj, key)
            out = obj.doRequest('GET', ['/v1/locks?key=', obj.enc(key)]);
        end

        function out = lockAcquire(obj, key, opts)
            arguments
                obj
                key
                opts.holder = []
                opts.ttl_ms = []
                opts.wait (1,1) logical = true
            end
            body = struct('key', key);
            body = obj.addOpt(body, 'holder', opts.holder);
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body.wait = opts.wait;
            out = obj.doRequest('POST', '/v1/locks/acquire', body);
        end

        function out = lockAcquireMany(obj, keys, opts)
            arguments
                obj
                keys
                opts.holder = []
                opts.ttl_ms = []
                opts.wait (1,1) logical = true
            end
            body = struct();
            body.keys = cellstr(keys);  % union lock over a string array
            body = obj.addOpt(body, 'holder', opts.holder);
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body.wait = opts.wait;
            out = obj.doRequest('POST', '/v1/locks/acquire', body);
        end

        function out = tryLock(obj, key, opts)
            arguments
                obj
                key
                opts.holder = []
                opts.ttl_ms = []
            end
            out = obj.lockAcquire(key, 'holder', opts.holder, 'ttl_ms', opts.ttl_ms, 'wait', false);
        end

        function grant = mustLock(obj, key, opts)
            % mustLock  Blocking acquire. The server does NOT hold the connection
            % on wait=true (it reserves a FIFO slot and returns immediately), so
            % this acquires then POLLS lockGet until this holder holds the lock,
            % or raises 'fiducia:lockTimeout' after max_wait_ms. Returns a held
            % grant struct (key, holder, fencing_token, lease_expires_ms) that you
            % can pass straight to lockRelease.
            arguments
                obj
                key
                opts.holder = []
                opts.ttl_ms = []
                opts.max_wait_ms (1,1) double = 30000
                opts.retry_interval_ms (1,1) double = 250
                opts.max_retries = []
            end
            grant = obj.acquireLockBlocking(key, opts.holder, opts.ttl_ms, ...
                opts.max_wait_ms, opts.retry_interval_ms, opts.max_retries);
        end

        function grant = lock(obj, key, opts)
            % lock  Alias for mustLock (blocking acquire that polls until held).
            arguments
                obj
                key
                opts.holder = []
                opts.ttl_ms = []
                opts.max_wait_ms (1,1) double = 30000
                opts.retry_interval_ms (1,1) double = 250
                opts.max_retries = []
            end
            grant = obj.mustLock(key, 'holder', opts.holder, 'ttl_ms', opts.ttl_ms, ...
                'max_wait_ms', opts.max_wait_ms, 'retry_interval_ms', opts.retry_interval_ms, ...
                'max_retries', opts.max_retries);
        end

        function out = lockRelease(obj, key, holder, fencing_token)
            % key is accepted for symmetry but is NOT sent in the body.
            body = struct('holder', holder, 'fencing_token', fencing_token);
            out = obj.doRequest('POST', '/v1/locks/release', body);
        end

        % --- semaphores ---
        function out = semaphoreGet(obj, key)
            out = obj.doRequest('GET', ['/v1/semaphores?key=', obj.enc(key)]);
        end

        function out = semaphoreAcquire(obj, key, limit, opts)
            arguments
                obj
                key
                limit
                opts.holder = []
                opts.ttl_ms = []
                opts.wait (1,1) logical = true
            end
            body = struct('key', key);
            body = obj.addOpt(body, 'holder', opts.holder);
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body.limit = limit;
            body.wait = opts.wait;
            out = obj.doRequest('POST', '/v1/semaphores/acquire', body);
        end

        function out = trySemaphore(obj, key, limit, opts)
            arguments
                obj
                key
                limit
                opts.holder = []
                opts.ttl_ms = []
            end
            out = obj.semaphoreAcquire(key, limit, 'holder', opts.holder, 'ttl_ms', opts.ttl_ms, 'wait', false);
        end

        function grant = mustSemaphore(obj, key, limit, opts)
            % mustSemaphore  Blocking acquire. Acquires (wait=true) then POLLS
            % semaphoreGet until this holder holds a permit, or raises
            % 'fiducia:semaphoreTimeout' after max_wait_ms. Returns a held grant
            % struct (key, holder, fencing_token, lease_expires_ms).
            arguments
                obj
                key
                limit
                opts.holder = []
                opts.ttl_ms = []
                opts.max_wait_ms (1,1) double = 30000
                opts.retry_interval_ms (1,1) double = 250
                opts.max_retries = []
            end
            grant = obj.acquireSemaphoreBlocking(key, limit, opts.holder, opts.ttl_ms, ...
                opts.max_wait_ms, opts.retry_interval_ms, opts.max_retries);
        end

        function grant = semaphore(obj, key, limit, opts)
            % semaphore  Alias for mustSemaphore (blocking acquire that polls).
            arguments
                obj
                key
                limit
                opts.holder = []
                opts.ttl_ms = []
                opts.max_wait_ms (1,1) double = 30000
                opts.retry_interval_ms (1,1) double = 250
                opts.max_retries = []
            end
            grant = obj.mustSemaphore(key, limit, 'holder', opts.holder, 'ttl_ms', opts.ttl_ms, ...
                'max_wait_ms', opts.max_wait_ms, 'retry_interval_ms', opts.retry_interval_ms, ...
                'max_retries', opts.max_retries);
        end

        function out = semaphoreRelease(obj, key, holder, fencing_token)
            body = struct('key', key, 'holder', holder, 'fencing_token', fencing_token);
            out = obj.doRequest('POST', '/v1/semaphores/release', body);
        end

        % --- idempotency ---
        function out = idempotencyGet(obj, key)
            out = obj.doRequest('GET', ['/v1/idempotency?key=', obj.enc(key)]);
        end

        function out = idempotencyClaim(obj, key, opts)
            arguments
                obj
                key
                opts.owner = []
                opts.ttl_ms = []
                opts.ttl = []
                opts.metadata = []  % arbitrary JSON object (struct)
            end
            body = struct('key', key);
            body = obj.addOpt(body, 'owner', opts.owner);
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body = obj.addOpt(body, 'ttl', opts.ttl);
            body = obj.addOpt(body, 'metadata', opts.metadata);
            out = obj.doRequest('POST', '/v1/idempotency/claim', body);
        end

        function out = idempotencyComplete(obj, key, owner, fencing_token, opts)
            arguments
                obj
                key
                owner
                fencing_token
                opts.result = []  % arbitrary JSON object (struct)
            end
            body = struct('key', key, 'owner', owner, 'fencing_token', fencing_token);
            body = obj.addOpt(body, 'result', opts.result);
            out = obj.doRequest('POST', '/v1/idempotency/complete', body);
        end

        % --- reader-writer locks ---
        function out = rwAcquireRead(obj, key, opts)
            arguments
                obj
                key
                opts.ttl_ms = []
                opts.wait (1,1) logical = true
            end
            body = struct();
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body.wait = opts.wait;
            out = obj.doRequest('POST', ['/v1/rw/', obj.enc(key), '/read'], body);
        end

        function out = rwEndRead(obj, key, lock_id)
            body = struct('lock_id', lock_id);
            out = obj.doRequest('POST', ['/v1/rw/', obj.enc(key), '/read/end'], body);
        end

        function out = rwAcquireWrite(obj, key, opts)
            arguments
                obj
                key
                opts.ttl_ms = []
                opts.wait (1,1) logical = true
            end
            body = struct();
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body.wait = opts.wait;
            out = obj.doRequest('POST', ['/v1/rw/', obj.enc(key), '/write'], body);
        end

        function out = rwEndWrite(obj, key, lock_id)
            body = struct('lock_id', lock_id);
            out = obj.doRequest('POST', ['/v1/rw/', obj.enc(key), '/write/end'], body);
        end

        % --- config KV ---
        function out = kvGet(obj, key)
            out = obj.doRequest('GET', ['/v1/kv?key=', obj.enc(key)]);
        end

        function out = kvPut(obj, key, value, opts)
            arguments
                obj
                key
                value
                opts.ttl_ms = []
                opts.prev_revision = []
            end
            body = struct();
            body.value = value;
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            body = obj.addOpt(body, 'prev_revision', opts.prev_revision);
            out = obj.doRequest('PUT', ['/v1/kv?key=', obj.enc(key)], body);
        end

        function out = kvDelete(obj, key)
            out = obj.doRequest('DELETE', ['/v1/kv?key=', obj.enc(key)]);
        end

        function out = kvList(obj, prefix)
            out = obj.doRequest('GET', ['/v1/kv?prefix=', obj.enc(prefix)]);
        end

        % --- rate limiting ---
        function out = rateLimitGet(obj, tenant, key)
            out = obj.doRequest('GET', ['/v1/rate-limit/', obj.enc(tenant), '/', obj.enc(key)]);
        end

        function out = rateLimitCheck(obj, tenant, key, algorithm, limit, window_ms, opts)
            arguments
                obj
                tenant
                key
                algorithm
                limit
                window_ms
                opts.refill_per_second = []
                opts.cost = []
            end
            body = struct('algorithm', algorithm, 'limit', limit, 'window_ms', window_ms);
            body = obj.addOpt(body, 'refill_per_second', opts.refill_per_second);
            body = obj.addOpt(body, 'cost', opts.cost);
            out = obj.doRequest('POST', ['/v1/rate-limit/', obj.enc(tenant), '/', obj.enc(key), '/check'], body);
        end

        % --- cron & scheduling ---
        function out = scheduleGet(obj, name)
            out = obj.doRequest('GET', ['/v1/cron/schedules/', obj.enc(name)]);
        end

        function out = scheduleUpsert(obj, name, target, opts)
            arguments
                obj
                name
                target  % arbitrary JSON object (struct), e.g. struct('kind','webhook','url','...')
                opts.cron = []
                opts.one_shot_at_ms = []
                opts.delivery = []
                opts.max_retries = []
            end
            body = struct();
            body.target = target;
            body = obj.addOpt(body, 'cron', opts.cron);
            body = obj.addOpt(body, 'one_shot_at_ms', opts.one_shot_at_ms);
            body = obj.addOpt(body, 'delivery', opts.delivery);
            body = obj.addOpt(body, 'max_retries', opts.max_retries);
            out = obj.doRequest('PUT', ['/v1/cron/schedules/', obj.enc(name)], body);
        end

        function out = scheduleRecordRun(obj, name, fire_id, opts)
            arguments
                obj
                name
                fire_id
                opts.fired_at_ms = []
            end
            body = struct('fire_id', fire_id);
            body = obj.addOpt(body, 'fired_at_ms', opts.fired_at_ms);
            out = obj.doRequest('POST', ['/v1/cron/schedules/', obj.enc(name), '/runs'], body);
        end

        function out = scheduleHistory(obj, name)
            out = obj.doRequest('GET', ['/v1/cron/schedules/', obj.enc(name), '/history']);
        end

        % --- leader election ---
        function out = electionGet(obj, name)
            out = obj.doRequest('GET', ['/v1/elections/', obj.enc(name)]);
        end

        function out = electionCampaign(obj, name, candidate, ttl_ms, opts)
            arguments
                obj
                name
                candidate
                ttl_ms
                opts.metadata = []
            end
            body = struct('candidate', candidate, 'ttl_ms', ttl_ms);
            body = obj.addOpt(body, 'metadata', opts.metadata);
            out = obj.doRequest('POST', ['/v1/elections/', obj.enc(name), '/campaign'], body);
        end

        function out = electionRenew(obj, name, candidate, fencing_token)
            body = struct('candidate', candidate, 'fencing_token', fencing_token);
            out = obj.doRequest('POST', ['/v1/elections/', obj.enc(name), '/renew'], body);
        end

        function out = electionResign(obj, name, candidate, fencing_token)
            body = struct('candidate', candidate, 'fencing_token', fencing_token);
            out = obj.doRequest('POST', ['/v1/elections/', obj.enc(name), '/resign'], body);
        end

        % --- service discovery ---
        function out = serviceInstances(obj, service)
            out = obj.doRequest('GET', ['/v1/services/', obj.enc(service)]);
        end

        function out = serviceRegister(obj, service, instance_id, address, ttl_ms, opts)
            arguments
                obj
                service
                instance_id
                address
                ttl_ms
                opts.metadata = []
            end
            body = struct('address', address, 'ttl_ms', ttl_ms);
            body = obj.addOpt(body, 'metadata', opts.metadata);
            out = obj.doRequest('PUT', ['/v1/services/', obj.enc(service), '/instances/', obj.enc(instance_id)], body);
        end

        function out = serviceHeartbeat(obj, service, instance_id, opts)
            arguments
                obj
                service
                instance_id
                opts.ttl_ms = []
            end
            body = struct();
            body = obj.addOpt(body, 'ttl_ms', opts.ttl_ms);
            out = obj.doRequest('POST', ['/v1/services/', obj.enc(service), '/instances/', obj.enc(instance_id), '/heartbeat'], body);
        end

        function out = serviceDeregister(obj, service, instance_id)
            out = obj.doRequest('DELETE', ['/v1/services/', obj.enc(service), '/instances/', obj.enc(instance_id)]);
        end

        function out = serviceList(obj)
            out = obj.doRequest('GET', '/v1/services');
        end
    end

    methods (Access = private)
        function out = doRequest(obj, method, path, body)
            % Core request. Pass a 4th argument to send a JSON body.
            url = [obj.BaseUrl, path];
            if nargin >= 4
                header = matlab.net.http.HeaderField('Content-Type', 'application/json');
                % Encode with jsonencode and hand matlab.net.http raw uint8 bytes so
                % it transmits them verbatim (a char/string body would be re-encoded).
                payloadBytes = unicode2native(jsonencode(body), 'UTF-8');
                request = matlab.net.http.RequestMessage(method, header, ...
                    matlab.net.http.MessageBody(payloadBytes));
            else
                request = matlab.net.http.RequestMessage(method);
            end

            % MaxRedirects=0: do NOT auto-follow 3xx. Following a redirect on a
            % mutating POST/PUT/DELETE could re-submit and duplicate the operation
            % (e.g. a lock grant / FIFO queue slot). A 3xx is >= 300, so it surfaces
            % through the normal error path below rather than being followed.
            if isempty(obj.RequestTimeout)
                options = matlab.net.http.HTTPOptions('SavePayload', true, ...
                    'MaxRedirects', 0);
            else
                options = matlab.net.http.HTTPOptions('SavePayload', true, ...
                    'MaxRedirects', 0, ...
                    'ConnectTimeout', obj.RequestTimeout, ...
                    'ResponseTimeout', obj.RequestTimeout);
            end

            % send() returns the response for any HTTP status (it does not throw
            % on 4xx/5xx), so the status code is read cleanly below.
            response = request.send(matlab.net.URI(url), options);
            statusCode = double(response.StatusCode);
            rawBody = obj.rawText(response);
            if statusCode >= 300
                obj.raiseHttpError(statusCode, rawBody);
            end
            out = obj.decodeText(rawBody);
        end

        function s = rawText(~, response)
            % Return the response body as a char row (raw, undecoded).
            payload = response.Body.Payload;
            if ~isempty(payload)
                s = native2unicode(reshape(payload, 1, []), 'UTF-8');
                return;
            end
            data = response.Body.Data;
            if isempty(data)
                s = '';
            elseif ischar(data)
                s = data;
            elseif isstring(data)
                s = char(data);
            else
                % matlab.net.http auto-decoded a JSON body; re-serialize so the
                % caller path can jsondecode uniformly.
                s = jsonencode(data);
            end
        end

        function data = decodeText(~, s)
            t = strtrim(s);
            if isempty(t)
                data = [];
            else
                data = jsondecode(t);
            end
        end

        function raiseHttpError(~, statusCode, rawBody)
            if isempty(rawBody)
                message = sprintf('fiducia: HTTP %d', statusCode);
            else
                message = sprintf('fiducia: HTTP %d: %s', statusCode, rawBody);
            end
            error(MException('fiducia:httpError', '%s', message));
        end

        function b = addOpt(~, b, name, value)
            % Add an optional field to the body only when a value was supplied
            % (omit-nulls; matters for CAS semantics).
            if ~isempty(value)
                b.(name) = value;
            end
        end

        function e = enc(~, s)
            % Percent-encode a string for a URL path segment or query value.
            % Encodes every octet except the RFC 3986 unreserved set.
            s = char(string(s));
            if isempty(s)
                e = '';
                return;
            end
            bytes = unicode2native(s, 'UTF-8');
            unreserved = uint8(['A':'Z', 'a':'z', '0':'9', '-', '_', '.', '~']);
            parts = cell(1, numel(bytes));
            for i = 1:numel(bytes)
                b = bytes(i);
                if any(b == unreserved)
                    parts{i} = char(b);
                else
                    parts{i} = sprintf('%%%02X', b);
                end
            end
            e = strjoin(parts, '');
        end

        function grant = acquireLockBlocking(obj, key, holder, ttl_ms, max_wait_ms, retry_interval_ms, max_retries)
            % Acquire (wait=true) then poll lockGet until held or timeout. Port of
            % the reference clients' _acquire_lock / poll_lock.
            if isempty(holder), holder = obj.genHolder(); end
            if isempty(ttl_ms), ttl_ms = 60000; end
            out = obj.outputOf(obj.lockAcquire(key, 'holder', holder, 'ttl_ms', ttl_ms, 'wait', true));
            if obj.isTrue(obj.fieldOr(out, 'acquired', false))
                grant = obj.grantStruct(key, holder, out);
                return;
            end
            startTic = tic;
            maxWaitS = max_wait_ms / 1000;
            intervalS = retry_interval_ms / 1000;
            attempt = 0;
            while isempty(max_retries) || attempt < max_retries
                attempt = attempt + 1;
                remainingS = maxWaitS - toc(startTic);
                if remainingS <= 0, break; end
                pause(min(intervalS, remainingS));
                % A union lock is held iff you hold its first member key.
                lk = obj.fieldOr(obj.lockGet(key), 'lock', []);
                if obj.holderMatches(lk, holder)
                    grant = obj.grantStruct(key, holder, lk);
                    return;
                end
            end
            obj.raiseTimeout('fiducia:lockTimeout', key, max_wait_ms);
        end

        function grant = acquireSemaphoreBlocking(obj, key, limit, holder, ttl_ms, max_wait_ms, retry_interval_ms, max_retries)
            % Acquire (wait=true) then poll semaphoreGet.holders until this holder
            % has a permit or timeout. Port of _acquire_semaphore / poll_semaphore.
            if isempty(holder), holder = obj.genHolder(); end
            if isempty(ttl_ms), ttl_ms = 60000; end
            out = obj.outputOf(obj.semaphoreAcquire(key, limit, 'holder', holder, 'ttl_ms', ttl_ms, 'wait', true));
            if obj.isTrue(obj.fieldOr(out, 'acquired', false))
                grant = obj.grantStruct(key, holder, out);
                return;
            end
            startTic = tic;
            maxWaitS = max_wait_ms / 1000;
            intervalS = retry_interval_ms / 1000;
            attempt = 0;
            while isempty(max_retries) || attempt < max_retries
                attempt = attempt + 1;
                remainingS = maxWaitS - toc(startTic);
                if remainingS <= 0, break; end
                pause(min(intervalS, remainingS));
                sem = obj.fieldOr(obj.semaphoreGet(key), 'semaphore', []);
                slot = obj.findHolder(obj.fieldOr(sem, 'holders', {}), holder);
                if ~isempty(slot)
                    grant = obj.grantStruct(key, holder, slot);
                    return;
                end
            end
            obj.raiseTimeout('fiducia:semaphoreTimeout', key, max_wait_ms);
        end

        function h = genHolder(~)
            % Unique holder id in the reference style ("fdc-" + token). tempname
            % yields an OS-unique token per call without creating a file or
            % disturbing the caller's global rng() state.
            [~, token] = fileparts(tempname);
            token = regexprep(token, '[^A-Za-z0-9]', '');
            if isempty(token)
                token = sprintf('%.0f', mod(now, 1) * 1e12);
            end
            h = ['fdc-', token];
        end

        function out = outputOf(obj, resp)
            % resp.result.output, or an empty struct when absent.
            out = obj.fieldOr(obj.fieldOr(resp, 'result', []), 'output', struct([]));
        end

        function g = grantStruct(obj, key, holder, src)
            % Held-grant view the caller can release; pulls fencing_token and
            % lease_expires_ms from src (an acquire output or a lockGet entry).
            g = struct('key', obj.asChar(key), 'holder', obj.asChar(holder), ...
                'fencing_token', obj.fieldOr(src, 'fencing_token', []), ...
                'lease_expires_ms', obj.fieldOr(src, 'lease_expires_ms', []));
        end

        function slot = findHolder(obj, holders, holder)
            % First holders entry matching holder with a non-null fencing_token.
            slot = [];
            if isempty(holders)
                return;
            elseif iscell(holders)
                items = holders;
            elseif isstruct(holders)
                items = num2cell(holders);
            else
                return;
            end
            for i = 1:numel(items)
                if obj.holderMatches(items{i}, holder)
                    slot = items{i};
                    return;
                end
            end
        end

        function tf = holderMatches(obj, entry, holder)
            % True when entry is a held record for holder: matching holder id and
            % a present (non-null) fencing_token.
            tf = false;
            if ~(isstruct(entry) && isscalar(entry)), return; end
            if ~isfield(entry, 'holder') || ~isfield(entry, 'fencing_token'), return; end
            if isempty(entry.fencing_token), return; end
            tf = strcmp(obj.asChar(entry.holder), obj.asChar(holder));
        end

        function tf = isTrue(~, v)
            % JSON-truthy scalar: logical true or a nonzero number.
            if isscalar(v) && islogical(v)
                tf = v;
            elseif isscalar(v) && isnumeric(v)
                tf = (v ~= 0);
            else
                tf = false;
            end
        end

        function v = fieldOr(~, s, name, default)
            % s.(name) when s is a scalar struct with that field, else default.
            if isstruct(s) && isscalar(s) && isfield(s, name)
                v = s.(name);
            else
                v = default;
            end
        end

        function s = asChar(~, v)
            % Normalize a char/string/scalar to a char row for compare/return.
            if ischar(v)
                s = v;
            else
                s = char(string(v));
            end
        end

        function raiseTimeout(~, identifier, key, max_wait_ms)
            error(MException(identifier, ...
                'fiducia: timed out after %dms waiting to acquire %s', ...
                round(max_wait_ms), char(string(key))));
        end
    end
end
