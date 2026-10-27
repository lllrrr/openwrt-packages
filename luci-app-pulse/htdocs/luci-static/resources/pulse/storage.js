'use strict';
'require baseclass';

function unescapeMount(value) {
 return value.replace(/\\([0-7]{3})/g, function(_, octal) {
  return String.fromCharCode(parseInt(octal, 8));
 });
}

return baseclass.extend({
 discover: function(mountinfo, capacities) {
  var mounts = mountinfo.split('\n').map(function(line) {
   var fields = line.split(' '), separator = fields.indexOf('-');
   if (fields.length < 10 || separator < 6) return null;
   return { id: fields[2], root: unescapeMount(fields[3]),
    mount: unescapeMount(fields[4]), type: fields[separator + 1],
    device: unescapeMount(fields[separator + 2]) };
  }).filter(Boolean);
  var system = new Set(mounts.filter(function(m) {
   return ['/', '/overlay', '/rom'].includes(m.mount);
  }).map(function(m) { return m.id; }));
  var stats = new Map(capacities.map(function(s) { return [s.mount, s]; }));
  var seen = new Set();
  return mounts.sort(function(a, b) {
   // Prefer familiar /mnt mounts when the same filesystem has multiple paths.
   return Number(!a.mount.startsWith('/mnt/')) - Number(!b.mount.startsWith('/mnt/')) ||
    a.mount.length - b.mount.length || a.mount.localeCompare(b.mount);
  }).filter(function(m) {
   if (m.mount === '/' || /^\/(?:proc|sys|dev|tmp|run|var|etc|usr|bin|sbin|lib|lib64|rom|overlay|boot)(?:\/|$)/.test(m.mount)) return false;
   if (system.has(m.id) || !m.device.startsWith('/dev/')) return false;
   // Subdirectory bind mounts are not extra disks. Btrfs subvolumes are valid.
   if (m.root !== '/' && m.type !== 'btrfs') return false;
   if (/^(?:tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|devpts|cgroup2?|autofs)$/.test(m.type)) return false;
   var s = stats.get(m.mount);
   if (!s || !Number.isFinite(s.size) || s.size <= 0) return false;
   var key = m.type === 'btrfs' ? m.device : m.id;
   if (seen.has(key)) return false;
   seen.add(key);
   return true;
  }).map(function(m) {
   var s = stats.get(m.mount);
   return { mount: m.mount, device: m.device, type: m.type,
    total: s.size, used: s.size - s.free, free: s.free, available: s.avail };
  });
 }
});
