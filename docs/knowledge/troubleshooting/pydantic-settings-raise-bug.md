# Pydantic settings `model_validator` must not call `self._raise()`

## Context

When adding a new TLS mode to `backend/app/core/config.py` (pydantic-settings `Settings` class), a `@model_validator(mode="after")` method `_tls_guards` was modified. Pydantic v2 `model_validator` runs after field validation and can collect errors then raise them.

## Problem

The following code **crashes at runtime**:

```python
# BAD — AttributeError: 'Settings' object has no attribute '_raise'
return self if not errors else self._raise(errors)
```

Pydantic v2's `BaseModel` does not have a `_raise` method. This call pattern only works in Pydantic v1's custom validators. The error surfaces as:

```
AttributeError: 'Settings' object has no attribute '_raise'
  File "config.py", line 262, in _tls_guards
    return self if not errors else self._raise(errors)
```

This is especially dangerous because:
- It only triggers when there **are** validation errors — code paths that pass validation silently succeed
- It can ship in a Docker image and only fail at `docker compose up` time when env vars trigger the validation path
- The original code had the same pattern for `nginx`/`direct` modes but those used `raise ValueError(...)` instead — the `_raise` call was a copy-paste error

## Solution

Replace the non-existent `self._raise()` with an explicit `ValueError`:

```python
# GOOD
if errors:
    raise ValueError("Configuration security violations: " + "; ".join(errors))
return self
```

The rest of the file already used this pattern at line 300-301. The `docker-compose` block was the only place using the broken `self._raise()` call.

## Why It Works

Pydantic v2's `model_validator(mode="after")` catches `ValueError` during model initialization and converts it into a `ValidationError` with the message preserved. This is the documented pattern for post-validation checks in pydantic-settings.

## Side Effects / Tradeoffs

None. This is a straight bug fix — the error message format and behavior are identical to the working `raise ValueError(...)` calls elsewhere in the same method.

## Evidence

- Before fix: `docker compose up` → backend restarts loop with `AttributeError: 'Settings' object has no attribute '_raise'`
- After fix: `docker compose up` → backend healthy, `Application startup complete` in logs
- All non-docker-compose TLS modes (`nginx`, `direct`) were unaffected — they already used `raise ValueError`

## Related Files

- `backend/app/core/config.py` — `_tls_guards` method, lines 253-262 (fixed)

## Tags

`pydantic` `pydantic-v2` `model-validator` `settings` `validation` `tls` `attribute-error`
