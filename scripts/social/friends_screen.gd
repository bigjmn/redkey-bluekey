extends SocialScreenBase
## Friends screen: send a request by friend code, act on incoming requests,
## and see the accepted friends list.

var _code_edit: LineEdit
var _requests_box: VBoxContainer
var _friends_box: VBoxContainer

func _screen_title() -> String:
	return "FRIENDS"

func _on_open() -> void:
	FirebaseSocial.friends_loaded.connect(_on_friends)
	FirebaseSocial.friend_requests_loaded.connect(_on_requests)

	var add_box := _section("Add a Friend")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_box.add_child(row)
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "Friend code (e.g. RK-7777)"
	_code_edit.custom_minimum_size = Vector2(0, 56)
	_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_edit.add_theme_font_size_override("font_size", 24)
	row.add_child(_code_edit)
	row.add_child(_button("Send Request", _send_request))

	_requests_box = _section("Friend Requests")
	_friends_box = _section("Friends")

	set_status("Loading…")
	FirebaseSocial.refresh_friends()

func _exit_tree() -> void:
	super()
	if FirebaseSocial.friends_loaded.is_connected(_on_friends):
		FirebaseSocial.friends_loaded.disconnect(_on_friends)
	if FirebaseSocial.friend_requests_loaded.is_connected(_on_requests):
		FirebaseSocial.friend_requests_loaded.disconnect(_on_requests)

func _send_request() -> void:
	set_status("Sending request…")
	var ok: bool = await FirebaseSocial.send_friend_request(_code_edit.text)
	if ok:
		_code_edit.text = ""
		set_status("Request sent")

func _on_requests(requests: Array) -> void:
	_clear(_requests_box)
	_requests_box.add_child(_label("Friend Requests", 26, C_ACCENT))
	var shown := 0
	for r: Dictionary in requests:
		if r.get("status", "") != "pending":
			continue
		shown += 1
		if r.get("direction", "incoming") == "incoming":
			var rid: String = r.get("id", "")
			_row(_requests_box, "%s wants to be friends" % r.get("fromDisplayName", "?"), [
				{text = "Accept", cb = func(): FirebaseSocial.respond_to_friend_request(rid, true)},
				{text = "Reject", cb = func(): FirebaseSocial.respond_to_friend_request(rid, false)},
			])
		else:
			_row(_requests_box, "Sent to %s — pending" % r.get("toDisplayName", "?"))
	if shown == 0:
		_requests_box.add_child(_label("No pending requests.", 21, C_SUB))

func _on_friends(friends: Array) -> void:
	set_status("")
	_clear(_friends_box)
	_friends_box.add_child(_label("Friends", 26, C_ACCENT))
	if friends.is_empty():
		_friends_box.add_child(_label("No friends yet — share your friend code from the Profile tab.", 21, C_SUB))
	for f: Dictionary in friends:
		_row(_friends_box, "%s   (%s)" % [f.get("displayName", "?"), f.get("friendCode", "")])
