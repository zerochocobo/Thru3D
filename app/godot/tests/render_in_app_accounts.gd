extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/test_cloud_accounts.gd").Platform
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_ACCOUNT_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	for language in ["zh", "en", "ja"]:
		I18n.use(language)
		var menu := Menu.new(); camera.add_child(menu)
		var platform := Platform.new(); menu.attach_platform(platform); menu.visible = true
		menu.section = Menu.Section.CLOUD
		var a: RefCounted = menu.account_panel
		for page in ["cloud_choose", "cloud_edit", "115", "115_open", "baidu", "aliyun_open", "quark_open", "onedrive", "webdav", "sms", "captcha", "server_choose", "emby", "stash", "dav", "license", "web", "web_keyboard"]:
			a.close()
			match page:
				"cloud_choose": a.open("cloud")
				"cloud_edit": a.open("cloud", true)
				"115", "sms", "captcha":
					a.kind = "cloud"; a.start("cloud", "115")
					a.data.fields.name = "115 · 家庭影音"; a.data.fields.username = "13800138000"; a.data.password_length = 12
					if page == "sms": a.view = "sms"; a.fields.assign(["sms"]); a.field = "sms"; a.data.sms_wait = 38; a.data.sms_sent = true; a.data.sms_length = 6
					if page == "captcha":
						a.view = "captcha"
						var image := Image.create(500, 200, false, Image.FORMAT_RGB8); image.fill(Color(0.95, 0.94, 0.9))
						a.choices = ImageTexture.create_from_image(image); a.prompt = a.choices; a.selected.assign([3, 1])
				"115_open", "baidu", "aliyun_open", "quark_open", "onedrive":
					a.kind = "cloud"; a.start("cloud", page); a.data.fields.name = a.provider_name(page)
				"webdav":
					a.kind = "cloud"; a.start("cloud", "webdav")
					a.data.fields.name = "WebDAV"; a.data.fields.base = "http://nas.example:19798/dav"; a.data.fields.username = "user@example.org"; a.data.password_length = 12
				"server_choose": a.open("server")
				"emby", "stash":
					menu.section = Menu.Section.MEDIA_SERVER; a.kind = "server"; a.start("server", page)
					a.data.fields.name = "客厅 NAS"; a.data.fields.base = "https://media.example.org:8096"; a.data.fields.username = "dennis"; a.data.password_length = 18
				"dav":
					a.kind = "cloud"; a.start("dav"); a.view = "dav"
					a.data.result = {"enabled": true, "addresses": ["http://192.168.31.100:9867/"], "password": "••••••••••••"}
				"license":
					menu.section = Menu.Section.SETTINGS; menu.tab = Menu.ABOUT_TAB
					a.show_license("p115rsacipher · MIT", menu._desktop_license_text("115"))
				"web", "web_keyboard":
					a.kind = "cloud"; a.start("cloud", "baidu"); a.view = "web"
					a.data.web = {"editing": page == "web_keyboard", "scroll_range": 2160, "scroll_y": 720, "height": 720}
					var image := Image.create(1200, 720, false, Image.FORMAT_RGB8); image.fill(Color(0.9, 0.93, 0.95))
					image.fill_rect(Rect2i(210, 130, 780, 360), Color.WHITE)
					image.fill_rect(Rect2i(270, 200, 660, 60), Color(0.75, 0.82, 0.86))
					image.fill_rect(Rect2i(270, 300, 660, 60), Color(0.75, 0.82, 0.86))
					a.web_texture = ImageTexture.create_from_image(image)
			camera.fov = 85 if page.begins_with("web") else 60
			menu.refresh()
			# Freeze snapshots for visual fixtures; real UI uses the production poll loop.
			a.paused = true
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
		menu.free(); platform.free()
	viewport.queue_free(); await process_frame
	print("in-app account previews rendered")
	quit()
