extends RefCounted

# Original vector glyphs, generated once and shared by both ray menus.
const PATHS := {
	"bookmark": '<path d="M6 3H18V21L12 17 6 21Z"/>',
	"bookmark_add": '<path d="M5 3H14M5 3V21L11 17 17 21V13M17 3V11M13 7H21"/>',
	"undo": '<path d="M8 5L3 10 8 15M3 10H14A6 6 0 0 1 14 22"/>',
	"media_library": '<rect x="3" y="7" width="18" height="14" rx="2"/><path d="M6 4H18M9 1H15M10 11L16 14 10 17Z"/>',
	"image": '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="2"/><path d="M3 18L10 11 14 15 18 10 21 14"/>',
	"images": '<rect x="7" y="3" width="14" height="14" rx="2"/><path d="M3 7V21H17M8 15L13 10 17 14 20 11"/>',
	"zoom": '<circle cx="10" cy="10" r="7"/><path d="M15 15L22 22M6 10H14M10 6V14"/>',
	"minus": '<path d="M5 12H19"/>',
	"search": '<circle cx="10" cy="10" r="6"/><path d="M15 15L21 21"/>',
	"time": '<circle cx="12" cy="12" r="9"/><path d="M12 6V12L16 15"/>',
	"list": '<path d="M9 5H21M9 12H21M9 19H21M3 5H4M3 12H4M3 19H4"/>',
	"plus": '<path d="M5 12H19M12 5V19"/>',
	"play": '<path d="M9 5L20 12 9 19Z" fill="white" stroke="none"/>',
	"pause": '<path d="M8 5V19M16 5V19" stroke-width="4"/>',
	"previous_video": '<path d="M6 5V19"/><path d="M19 5L8 12 19 19Z" fill="white" stroke="none"/>',
	"next_video": '<path d="M18 5V19"/><path d="M5 5L16 12 5 19Z" fill="white" stroke="none"/>',
	"back": '<path d="M13 6L7 12 13 18M20 6L14 12 20 18"/>',
	"forward": '<path d="M4 6L10 12 4 18M11 6L17 12 11 18"/>',
	"folder": '<path d="M3 7V19H21V8H12L10 5H3V7Z"/>',
	"library": '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8H16M8 12H16M8 16H13"/>',
	"alpha": '<circle cx="12" cy="6" r="3"/><path d="M5 21V17C5 10 19 10 19 17V21M8 17V21M16 17V21"/>',
	"loop": '<path d="M4 9C4 3 20 3 20 9V11M17 8L20 11 23 8M20 15C20 21 4 21 4 15V13M1 16L4 13 7 16"/>',
	"stop": '<rect x="6" y="6" width="12" height="12" rx="1"/>',
	"close": '<path d="M6 6L18 18M18 6L6 18"/>',
	"stereo": '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M12 5V19"/>',
	"eyes": '<path d="M3 7H21M17 3L21 7 17 11M21 17H3M7 13L3 17 7 21"/>',
	"view_mode": '<path d="M5 6H19A3 3 0 0 1 22 9V15A3 3 0 0 1 19 18H16L13.5 15H10.5L8 18H5A3 3 0 0 1 2 15V9A3 3 0 0 1 5 6Z"/><circle cx="7.5" cy="11.5" r="2"/><circle cx="16.5" cy="11.5" r="2"/>',
	"panorama": '<path d="M3 5Q12 1 21 5V15Q12 11 3 15ZM3 18C3 22 21 22 21 18M18 19L21 17 22 20"/>',
	"quality": '<path d="M12 2L21 7V17L12 22 3 17V7Z"/><path d="M8 12L11 15 16 9"/>',
	"recenter": '<path d="M3 9V3H9M15 3H21V9M21 15V21H15M9 21H3V15"/><circle cx="12" cy="12" r="3"/>',
	"sound": '<path d="M3 9H7L12 5V19L7 15H3ZM15.5 9A4.5 4.5 0 0 1 15.5 15M18.5 5.5A9 9 0 0 1 18.5 18.5"/>',
	"volume_low": '<path d="M3 9H7L12 5V19L7 15H3ZM15.5 9A4.5 4.5 0 0 1 15.5 15"/>',
	"mute": '<path d="M3 9H7L12 5V19L7 15H3ZM16 9L22 15M22 9L16 15"/>',
	"audio": '<path d="M6 16V4H19V16M6 7H19"/><circle cx="3.5" cy="17" r="3"/><circle cx="16.5" cy="17" r="3"/>',
	"subtitle": '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M10 9C5 7 5 17 10 15M18 9C13 7 13 17 18 15"/>',
	"info": '<circle cx="12" cy="12" r="9"/><path d="M12 11V17M12 7V7.1"/>',
	"device": '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20H16M12 16V20"/>',
	"server": '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5H7.1M7 17.5H7.1"/>',
	"cast": '<path d="M3 7V5H21V19H14M3 11C7 11 10 14 10 18M3 15C5 15 6 16 6 18M3 18.5V18.6"/>',
	"cloud": '<path d="M6 19a5 5 0 0 1-1-9.9A7 7 0 0 1 18.4 8a5.5 5.5 0 0 1-.9 11Z"/>',
	"settings": '<path d="M10.2 4.6 10.3 2.1 13.7 2.1 13.8 4.6 15.9 5.5 17.8 3.8 20.2 6.2 18.5 8.1 19.4 10.2 21.9 10.3 21.9 13.7 19.4 13.8 18.5 15.9 20.2 17.8 17.8 20.2 15.9 18.5 13.8 19.4 13.7 21.9 10.3 21.9 10.2 19.4 8.1 18.5 6.2 20.2 3.8 17.8 5.5 15.9 4.6 13.8 2.1 13.7 2.1 10.3 4.6 10.2 5.5 8.1 3.8 6.2 6.2 3.8 8.1 5.5Z"/><circle cx="12" cy="12" r="3"/>',
	"refresh": '<path d="M20 12A8 8 0 1 1 17.7 6.3M20 4V9H15"/>',
	"up": '<path d="M15 6L9 12 15 18"/>',
	"next": '<path d="M9 6L15 12 9 18"/>',
	"previous": '<path d="M15 6L9 12 15 18"/>',
	"circle": '<circle cx="12" cy="12" r="7"/>',
	"edit": '<path d="M4 20H8L19 9 15 5 4 16Z"/>',
	"backspace": '<path d="M8 5H21V19H8L2 12Z"/><path d="M11 9L17 15M17 9L11 15"/>',
	"check": '<path d="M4 12L10 18 20 6"/>',
	"trash": '<path d="M4 7H20M9 7V4H15V7M6 7L7 21H17L18 7M10 11V17M14 11V17"/>',
	"screen": '<rect x="3" y="5" width="18" height="12" rx="1.5"/><path d="M9 20H15"/>',
	"dome": '<path d="M3 17A9 9 0 0 1 21 17Z"/><path d="M12 8V17M7.5 9.5L9.5 17M16.5 9.5L14.5 17"/>',
	"fisheye": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/>',
	"more": '<circle cx="5" cy="12" r="1.6" fill="white"/><circle cx="12" cy="12" r="1.6" fill="white"/><circle cx="19" cy="12" r="1.6" fill="white"/>',
	"hourglass": '<path d="M6 3H18M6 21H18M7 3C7 9 17 9 17 12S7 15 7 21M17 3C17 9 7 9 7 12S17 15 17 21"/>',
	"video": '<rect x="2" y="5" width="15" height="14" rx="2"/><path d="M17 10L22 7V17L17 14"/>',
	"depth": '<rect x="2" y="8" width="13" height="11" rx="1.5"/><path d="M6 8V5H22V16H15"/><path d="M6 15L9 12 12 15"/>',
	"stacked": '<rect x="4" y="2" width="16" height="20" rx="3"/><path d="M4 12H20"/>',
	"history": '<path d="M3 12A9 9 0 1 0 6 5.3M3 3V8H8"/><path d="M12 7V12L15 14"/>',
	"usb": '<path d="M12 2V17M12 2L9 5M12 2L15 5M12 11L7 8V6M12 13L17 10V8"/><circle cx="12" cy="19" r="2.5"/><rect x="5.5" y="4.5" width="3" height="2"/><circle cx="17" cy="7" r="1.3"/>',
	"battery": '<rect x="7" y="4" width="10" height="18" rx="2"/><path d="M10 2H14"/>',
	"bolt": '<path d="M13.5 6.5L9 13.5H12.2L10.5 19.5 15 12.5H11.8Z" fill="white" stroke="none"/>',
	"lock": '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7A4 4 0 0 1 16 7V11"/>',
	"unlock": '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7A4 4 0 0 1 15.5 5"/>',
	"voice": '<circle cx="8" cy="8" r="3.5"/><path d="M2 21C2 15.5 14 15.5 14 21M17 6.5A4 4 0 0 1 17 12.5M20 4A8 8 0 0 1 20 15"/>'}
static var _textures: Dictionary = {}

static func texture(key: String) -> Texture2D:
	if not _textures.has(key):
		var image := Image.new()
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>' % PATHS.get(key, PATHS.info)
		if image.load_svg_from_string(svg) != OK:
			return null
		_textures[key] = ImageTexture.create_from_image(image)
	return _textures[key]
