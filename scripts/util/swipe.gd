class_name Swipe
extends RefCounted
## Touch helper: map a raw swipe delta to a 4-direction grid step. Isolated as a
## pure function so the swipe-vector -> direction mapping can be unit-tested
## without live input (mobile-controls otherwise skips testing).

## Returns the dominant axis direction, or Vector2i.ZERO if the swipe is shorter
## than `threshold`. Screen space: +y is down.
static func to_dir(delta: Vector2, threshold: float) -> Vector2i:
	if delta.length() < threshold:
		return Vector2i.ZERO
	if absf(delta.x) >= absf(delta.y):
		return Vector2i.RIGHT if delta.x > 0.0 else Vector2i.LEFT
	return Vector2i.DOWN if delta.y > 0.0 else Vector2i.UP
