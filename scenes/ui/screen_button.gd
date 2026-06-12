extends TextureButton


signal clicked(button)


func _on_pressed() -> void:
	clicked.emit(self)
