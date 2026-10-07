import { popen } from 'fs';

// Does proc.read() block until data, or return null/empty on EAGAIN?
let p = popen("sh -c 'sleep 2; echo hi'", 'r');
let t0 = time();
let c = p.read(16384);
let dt = time() - t0;
let d = "NULL";
if (c != null) d = sprintf("len=%d %s", length(c), c);
printf("immediate read after spawn: %s  (type=%s, elapsed=%ds)\n", d, type(c), dt);

// second read, right after: is it empty again?
let t1 = time();
let c2 = p.read(16384);
let d2 = "NULL";
if (c2 != null) d2 = sprintf("len=%d", length(c2));
printf("second read: %s (elapsed=%ds)\n", d2, time() - t1);
p.close();
printf("POPEN_METHODS id=%s\n", p);
