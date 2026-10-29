
(function (global) {
	'use strict';

	var PAGE_SIZE = 65536;
	var MAX_PAGES = 64;            

	function HarborByteSource(path, total, io) {
		this.path = path;
		this.io = io || global.HarborIO;
		if (!Number.isSafeInteger(total) || total < 0) throw new Error('Invalid file size');
		this.total = total;
		this.generation = 0;
		this.pages = new Map();      
		this.lru = [];               
		this.pending = new Map();    
		this.overlay = new Map();    
	}

	HarborByteSource.prototype._touch = function (index) {
		var pos = this.lru.indexOf(index);
		if (pos >= 0)
			this.lru.splice(pos, 1);
		this.lru.push(index);

		while (this.lru.length > MAX_PAGES) {
			var victim = this.lru.shift();
			this.pages.delete(victim);
		}
	};

	HarborByteSource.prototype._loadPage = function (index) {
		var self = this, generation = this.generation;

		if (this.pages.has(index)) {
			this._touch(index);
			return Promise.resolve();
		}

		if (this.pending.has(index))
			return this.pending.get(index);

		var offset = index * PAGE_SIZE;
		var length = Math.min(PAGE_SIZE, this.total - offset);

		var p = this.io.slice(this.path, offset, length)
			.then(function (res) {
				if (generation !== self.generation) return;
				if (res.offset !== offset || res.total !== self.total || res.buffer.byteLength !== length) throw new Error('File size or page changed; reopen the file');
				self.pages.set(index, new Uint8Array(res.buffer));
				self._touch(index);
			}).finally(function () {
				if (self.pending.get(index) === p) self.pending.delete(index);
			});

		this.pending.set(index, p);
		return p;
	};

	HarborByteSource.prototype.ensure = function (offset, length) {
		if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length < 0 || !Number.isSafeInteger(offset + length) || length > PAGE_SIZE * MAX_PAGES) return Promise.reject(new Error('Invalid page range'));
		if (!length || offset >= this.total)
			return Promise.resolve();

		var end = Math.min(offset + length, this.total);
		var first = Math.floor(offset / PAGE_SIZE);
		var last = Math.floor((end - 1) / PAGE_SIZE);
		var jobs = [];

		for (var i = first; i <= last; i++)
			jobs.push(this._loadPage(i));

		return Promise.all(jobs);
	};

	HarborByteSource.prototype.prefetchAround = function (offset, length) {
		var lead = Math.min(offset + length + PAGE_SIZE, this.total);
		var trail = Math.max(offset - PAGE_SIZE, 0);

		this.ensure(trail, PAGE_SIZE);
		this.ensure(lead, PAGE_SIZE);
	};

	HarborByteSource.prototype.get = function (offset, length) {
		var end = Math.min(offset + length, this.total);
		var out = new Uint8Array(Math.max(end - offset, 0));

		for (var i = 0; i < out.length; i++) {
			var abs = offset + i;
			var index = Math.floor(abs / PAGE_SIZE);
			var page = this.pages.get(index);

			out[i] = page ? page[abs - index * PAGE_SIZE] : 0;

			if (this.overlay.has(abs))
				out[i] = this.overlay.get(abs);
		}

		return out;
	};

	HarborByteSource.prototype.setByte = function (offset, value) {
		if (offset < 0 || offset >= this.total)
			return false;
		this.overlay.set(offset, value & 0xFF);
		return true;
	};

	HarborByteSource.prototype.isDirty = function (offset) {
		return this.overlay.has(offset);
	};

	HarborByteSource.prototype.dirtyCount = function () {
		return this.overlay.size;
	};

	HarborByteSource.prototype.discard = function () {
		this.overlay.clear();
	};

	HarborByteSource.prototype.patches = function () {
		var offsets = Array.from(this.overlay.keys()).sort(function (a, b) { return a - b; });
		var runs = [];
		var current = null;

		for (var i = 0; i < offsets.length; i++) {
			var off = offsets[i];

			if (current && off === current.offset + current.values.length) {
				current.values.push(this.overlay.get(off));
			}
			else {
				if (current)
					runs.push({ offset: current.offset, bytes: new Uint8Array(current.values) });
				current = { offset: off, values: [ this.overlay.get(off) ] };
			}
		}

		if (current)
			runs.push({ offset: current.offset, bytes: new Uint8Array(current.values) });

		return runs;
	};

	HarborByteSource.prototype.setPath = function (path) {
		this.path = path;
		this.invalidate();
	};

	HarborByteSource.prototype.invalidate = function () {
		this.generation++;
		this.pending.clear();
		this.pages.clear();
		this.lru = [];
		this.overlay.clear();
	};

	HarborByteSource.prototype.save = function (on_progress) {
		var self = this;
		var runs = this.patches();

		if (!runs.length)
			return Promise.resolve({ written: 0, runs: 0 });

		var written = 0;

		return runs.reduce(function (chain, run, index) {
			return chain.then(function () {
				if (on_progress)
					on_progress(index, runs.length, written);
				return self.io.patch(self.path, run.offset, run.bytes, self.total)
					.then(function () { written += run.bytes.length; });
			});
		}, Promise.resolve()).then(function () {
			if (on_progress)
				on_progress(runs.length, runs.length, written);
			self.invalidate();

			return { written: written, runs: runs.length };
		});
	};

	HarborByteSource.prototype.search = function (needle, opts) {
		return this.io.search(this.path, needle, opts);
	};

	global.HarborByteSource = HarborByteSource;
})(window);
