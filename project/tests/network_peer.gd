extends SceneTree
## Real ENet regression. Run through tools/test_network.ps1, which starts two
## headless engine processes on loopback and records each peer's evidence.

const Fixture = preload("res://tests/rig_fixture.gd")
var rig: Dictionary
var api: SceneMultiplayer
var peer := ENetMultiplayerPeer.new()
var role := ""
var port := 19877
var remote_peer := 0
var stage := "starting"
var checks := 0
var done := false

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
	call_deferred("start")

func start() -> void:
	if role not in ["server", "client"]:
		fail("missing --role=server/client")
		return
	api = root.get_multiplayer() as SceneMultiplayer
	api.peer_packet.connect(on_packet)
	api.connection_failed.connect(func(): fail("ENet connection failed"))
	api.server_disconnected.connect(func():
		if not done: fail("authority disconnected before completion")
	)
	create_timer(25).timeout.connect(func():
		if not done: fail("timed out at stage " + stage)
	)
	rig = Fixture.make_rig()
	rig.component.network_enabled = true
	root.add_child(rig.actor)
	await process_frame
	await process_frame
	if not expect(rig.component.initialize(), "native component initialized"):
		return
	peer.set_bind_ip("127.0.0.1")
	if role == "server":
		if not expect(peer.create_server(port, 1) == OK, "loopback ENet server listening"):
			return
		api.multiplayer_peer = peer
		# The first cut predates the client connection: it must be recovered from
		# the native late-join snapshot, rather than a live cut notification.
		rig.component.dismember_limb(&"lower", Vector3(.1, .2, 0))
		if not expect(rig.component.get_dismembered_bones().has("lower"), "authority cut before client joins"):
			return
		stage = "late_join"
		print("GODOT_DISMEMBERMENT_NETWORK_SERVER_READY port=", port)
	else:
		api.connected_to_server.connect(client_connected)
		if not expect(peer.create_client("127.0.0.1", port) == OK, "loopback ENet client created"):
			return
		api.multiplayer_peer = peer
		stage = "connecting"

func expect(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		fail(message)
		return false
	print("NETWORK_CHECK role=", role, " ", message)
	return true

func fail(message: String) -> void:
	if done:
		return
	done = true
	printerr("GODOT_DISMEMBERMENT_NETWORK_FAIL role=", role, " stage=", stage, " reason=", message)
	quit(1)

func send_message(peer_id: int, data: Dictionary) -> void:
	var error := api.send_bytes(JSON.stringify(data).to_utf8_buffer(), peer_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)
	if error != OK:
		fail("coordinator packet failed: " + str(error))

func on_packet(peer_id: int, bytes: PackedByteArray) -> void:
	var parsed = JSON.parse_string(bytes.get_string_from_utf8())
	if parsed is Dictionary:
		call_deferred("handle_message", peer_id, parsed)
	else:
		fail("invalid coordinator packet")

func wait_for_bone(bone: String, present: bool, seconds: float = 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not done and Time.get_ticks_msec() < deadline:
		if rig.component.get_dismembered_bones().has(bone) == present:
			return true
		await process_frame
	return false

func client_connected() -> void:
	stage = "late_join"
	if not expect(await wait_for_bone("lower", true), "native late-join snapshot restores preconnection cut"):
		return
	if not expect(rig.component.get_all_dismembered_limbs().size() == 1, "late join creates one detached limb"):
		return
	send_message(1, {"kind": "late_join_ok"})

func handle_message(peer_id: int, data: Dictionary) -> void:
	if done:
		return
	var kind: String = data.get("kind", "")
	if role == "server":
		remote_peer = peer_id
		match kind:
			"late_join_ok":
				if not expect(stage == "late_join", "late-join acknowledgement received"):
					return
				rig.component.owning_peer_id = 0
				stage = "nonowner"
				send_message(peer_id, {"kind": "request_nonowner"})
			"nonowner_done":
				if not expect(stage == "nonowner" and not rig.component.get_dismembered_bones().has("other"), "authority rejects a nonowner client cut"):
					return
				rig.component.owning_peer_id = peer_id
				stage = "owner"
				send_message(peer_id, {"kind": "request_owner"})
			"owner_done":
				if not expect(stage == "owner" and rig.component.get_dismembered_bones().has("other"), "authorized client request applied on authority"):
					return
				stage = "broadcast"
				rig.component.dismember_limb(&"upper", Vector3(.2, 0, 0))
				send_message(peer_id, {"kind": "check_broadcast"})
			"broadcast_done":
				if not expect(stage == "broadcast", "client confirms authority cut broadcast"):
					return
				stage = "duplicate"
				rig.component.synchronize_peer(peer_id)
				rig.component.synchronize_peer(peer_id)
				send_message(peer_id, {"kind": "check_duplicate"})
			"duplicate_done":
				if not expect(stage == "duplicate", "duplicate snapshots acknowledged"):
					return
				stage = "reset"
				rig.component.reset_all_limbs()
				send_message(peer_id, {"kind": "check_reset"})
			"reset_done":
				if not expect(stage == "reset" and rig.component.get_dismembered_bones().is_empty(), "authority reset has cleared all missing bones"):
					return
				send_message(peer_id, {"kind": "complete"})
				await create_timer(.3).timeout
				finish()
			_:
				fail("unexpected server coordinator message " + kind)
	else:
		if not expect(peer_id == 1, "coordinator packet came from authority"):
			return
		match kind:
			"request_nonowner":
				stage = "nonowner"
				rig.component.dismember_limb(&"other", Vector3(.1, 0, 0))
				await create_timer(.35).timeout
				if not expect(not rig.component.get_dismembered_bones().has("other"), "nonowner client cannot mutate local cut state"):
					return
				send_message(1, {"kind": "nonowner_done"})
			"request_owner":
				stage = "owner"
				rig.component.dismember_limb(&"other", Vector3(.1, 0, 0))
				if not expect(await wait_for_bone("other", true), "authorized request returns through native authority broadcast"):
					return
				send_message(1, {"kind": "owner_done"})
			"check_broadcast":
				stage = "broadcast"
				if not expect(await wait_for_bone("upper", true), "authority cut reaches client over ENet"):
					return
				if not expect(rig.component.get_all_dismembered_limbs().size() == 3, "earlier cuts stay distinct after parent cut"):
					return
				send_message(1, {"kind": "broadcast_done"})
			"check_duplicate":
				stage = "duplicate"
				await create_timer(.25).timeout
				if not expect(rig.component.get_all_dismembered_limbs().size() == 3, "reliable duplicate snapshots do not duplicate physics limbs"):
					return
				send_message(1, {"kind": "duplicate_done"})
			"check_reset":
				stage = "reset"
				if not expect(await wait_for_bone("lower", false), "authority reset reaches client over ENet"):
					return
				if not expect(rig.component.get_dismembered_bones().is_empty() and rig.component.get_all_dismembered_limbs().is_empty(), "replicated reset removes missing bones and detached physics limbs"):
					return
				send_message(1, {"kind": "reset_done"})
			"complete":
				finish()
			_:
				fail("unexpected client coordinator message " + kind)

func finish() -> void:
	if done:
		return
	done = true
	stage = "complete"
	rig.component.clean_up_all_referenced_limbs()
	rig.actor.queue_free()
	await process_frame
	await process_frame
	peer.close()
	print("GODOT_DISMEMBERMENT_NETWORK_PASS role=", role, " checks=", checks)
	quit(0)
