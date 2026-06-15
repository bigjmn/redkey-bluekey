class_name FirebaseCrashlyticsHelper
extends RefCounted

# Automatically dispatches to the correct native set_custom_value_* based on [param value] type.
static func set_custom_value(crashlytics: Object, key: String, value) -> void:
	if crashlytics == null:
		return

	match typeof(value):
		TYPE_BOOL:
			crashlytics.set_custom_value_bool(key, value)
		TYPE_INT:
			crashlytics.set_custom_value_int(key, value)
		TYPE_FLOAT:
			crashlytics.set_custom_value_float(key, value)
		_:
			crashlytics.set_custom_value_string(key, str(value))
