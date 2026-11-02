"""Tiny YAML emitter for mihomo configs.

The only consumer is :mod:`cfpick.core`, which needs to write a handful
of nested dictionaries/lists.  Strings are emitted as JSON double-quoted
scalars, which are valid YAML, so no escaping surprises.
"""

import json
import re

_PLAIN_KEY = re.compile(r"^[A-Za-z0-9_.-]+$")


def _scalar(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, dict):
        return "{}"
    if isinstance(value, list):
        return "[]"
    if isinstance(value, (int, float)):
        return repr(value)
    return json.dumps(str(value), ensure_ascii=False)


def _key(name):
    name = str(name)
    return name if _PLAIN_KEY.match(name) else json.dumps(name, ensure_ascii=False)


def _emit(value, indent, lines):
    pad = " " * indent
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, dict) and item:
                lines.append("%s%s:" % (pad, _key(key)))
                _emit(item, indent + 2, lines)
            elif isinstance(item, list) and item:
                lines.append("%s%s:" % (pad, _key(key)))
                _emit(item, indent + 2, lines)
            else:
                lines.append("%s%s: %s" % (pad, _key(key), _scalar(item)))
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict) and item:
                first = True
                for key, sub in item.items():
                    if first:
                        prefix = "%s- %s" % (pad, _key(key))
                        first = False
                    else:
                        prefix = "%s  %s" % (pad, _key(key))
                    if isinstance(sub, (dict, list)) and sub:
                        lines.append(prefix + ":")
                        _emit(sub, indent + 4, lines)
                    else:
                        lines.append("%s: %s" % (prefix, _scalar(sub)))
            elif isinstance(item, list) and item:
                lines.append("%s-" % pad)
                _emit(item, indent + 2, lines)
            else:
                lines.append("%s- %s" % (pad, _scalar(item)))
    else:
        lines.append("%s%s" % (pad, _scalar(value)))


def dumps(value):
    lines = []
    _emit(value, 0, lines)
    return "\n".join(lines) + "\n"
