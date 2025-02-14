/*
 * This file is part of budgie-desktop
 *
 * Copyright Budgie Desktop Developers
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

 public class SoundInputRavenPlugin : Budgie.RavenPlugin, Peas.ExtensionBase {
	public Budgie.RavenWidget new_widget_instance(string uuid, GLib.Settings? settings) {
		return new SoundInputRavenWidget(uuid, settings);
	}

	public bool supports_settings() {
		return true;
	}
}

public class SoundInputRavenWidget : Budgie.RavenWidget {
	private Settings? budgie_settings = null;
	private ulong scale_id = 0;
	private Gvc.MixerControl mixer = null;
	private HashTable<string,string?> derpers;
	private HashTable<uint,Gtk.ListBoxRow?> devices;
	private ulong primary_notify_id = 0;
	private Gvc.MixerStream? primary_stream = null;

	/**
	 * Signals
	 */
	public signal void devices_state_changed(); // devices_state_changed is triggered when the amount of devices has changed

	/**
	 * Widgets
	 */
	private Gtk.Box? main_box = null;
	private Gtk.ListBox? devices_list = null;
	private Gtk.Box? header = null;
	private Gtk.Button? header_icon = null;
	private Gtk.Button? header_reveal_button = null;
	private Gtk.Revealer? content_revealer = null;
	private Gtk.Box? content = null;
	private Gtk.Scale? volume_slider = null;

	public SoundInputRavenWidget(string uuid, GLib.Settings? settings) {
		initialize(uuid, settings);

		main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		add(main_box);

		header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		header.get_style_context().add_class("raven-header");
		main_box.add(header);

		header_icon = new Gtk.Button.from_icon_name("microphone-sensitivity-muted-symbolic", Gtk.IconSize.MENU);
		header_icon.get_style_context().add_class("flat");
		header_icon.valign = Gtk.Align.CENTER;
		header_icon.margin = 4;
		header_icon.margin_start = 8;
		header_icon.margin_end = 4;
		header_icon.clicked.connect(() => {
			if (primary_stream != null) {
				primary_stream.change_is_muted(!primary_stream.get_is_muted());
			}
		});
		header.add(header_icon);

		content = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
		content.get_style_context().add_class("raven-background");

		content_revealer = new Gtk.Revealer();
		content_revealer.add(content);
		main_box.add(content_revealer);

		get_style_context().add_class("audio-widget");

		/**
		 * Shared  Logic
		 */
		mixer = new Gvc.MixerControl("Budgie Volume Control");

		mixer.card_added.connect((id) => { // When we add a card
			devices_state_changed();
		});

		mixer.card_removed.connect((id) => { // When we remove a card
			devices_state_changed();
		});

		derpers = new HashTable<string,string?>(str_hash, str_equal); // Create our GVC Stream app derpers
		derpers.insert("Vivaldi", "vivaldi"); // Vivaldi
		derpers.insert("Vivaldi Snapshot", "vivaldi-snapshot"); // Vivaldi Snapshot
		devices = new HashTable<uint,Gtk.ListBoxRow?>(direct_hash, direct_equal);

		/**
		 * Shared Construction
		 */
		devices_list = new Gtk.ListBox();
		devices_list.get_style_context().add_class("devices-list");
		devices_list.get_style_context().add_class("sound-devices");
		devices_list.selection_mode = Gtk.SelectionMode.SINGLE;
		devices_list.row_selected.connect(on_device_selected);

		volume_slider = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 10);
		volume_slider.set_draw_value(false);
		volume_slider.value_changed.connect(on_scale_change);
		volume_slider.hexpand = true;
		header.add(volume_slider);

		header_reveal_button = new Gtk.Button.from_icon_name("pan-end-symbolic", Gtk.IconSize.MENU);
		header_reveal_button.get_style_context().add_class("flat");
		header_reveal_button.get_style_context().add_class("expander-button");
		header_reveal_button.margin = 4;
		header_reveal_button.valign = Gtk.Align.CENTER;
		header_reveal_button.clicked.connect(() => {
			content_revealer.reveal_child = !content_revealer.child_revealed;
			var image = (Gtk.Image?) header_reveal_button.get_image();
			if (content_revealer.reveal_child) {
				image.set_from_icon_name("pan-down-symbolic", Gtk.IconSize.MENU);
			} else {
				image.set_from_icon_name("pan-end-symbolic", Gtk.IconSize.MENU);
			}
		});
		header.pack_end(header_reveal_button, false, false, 0);

		budgie_settings = new Settings("com.solus-project.budgie-panel");

		mixer.default_source_changed.connect(on_device_changed);
		mixer.state_changed.connect(on_state_changed);
		mixer.input_added.connect(on_device_added);
		mixer.input_removed.connect(on_device_removed);

		content.pack_start(devices_list, false, false, 0); // Add devices directly to layout

		// Add marks when sound slider can go beyond 100%
		settings.changed.connect(settings_updated);
		settings_updated("allow-volume-overdrive");

		mixer.open();

		/**
		 * Widget Expansion
		 */

		show_all();
	}

	/**
	 * has_devices will check if we have devices associated with this type
	 */
	public bool has_devices() {
		return (devices.size() != 0) && (mixer.get_cards().length() != 0);
	}

	/**
	 * on_device_added will handle when an input or output device has been added
	 */
	private void on_device_added(uint id) {
		if (devices.contains(id)) { // If we already have this device
			return;
		}

		var device = mixer.lookup_input_id(id);

		if (device == null) {
			return;
		}

		if (device.card == null) {
			return;
		}

		var card = device.card as Gvc.MixerCard;

		var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
		box.margin_start = 6;
		box.margin_end = 6;
		box.margin_top = 3;
		box.margin_bottom = 3;

		var label = new Gtk.Label("%s - %s".printf(device.description, card.name)) {
			valign = Gtk.Align.CENTER,
			xalign = 0.0f,
			max_width_chars = 1,
			ellipsize = Pango.EllipsizeMode.END,
			hexpand = true,
		};
		box.pack_start(label, false, true, 0);

		Gtk.ListBoxRow list_item = new Gtk.ListBoxRow();
		list_item.add(box);

		list_item.set_data("device_id", id);
		devices_list.insert(list_item, -1); // Append item

		devices.insert(id, list_item);
		list_item.show_all();
		devices_list.queue_draw();

		devices_state_changed();
	}

	/**
	 * on_device_changed will handle when a Gvc.MixerUIDevice has been changed
	 */
	private void on_device_changed(uint id) {
		Gvc.MixerStream stream = mixer.get_default_source(); // Set default_stream to the respective source or sink

		if (stream == null) { // Our default stream is null
			return;
		}

		if (stream == this.primary_stream) { // Didn't really change
			return;
		}

		var device = mixer.lookup_device_from_stream(stream);
		Gtk.ListBoxRow list_item = devices.lookup(device.get_id());

		if (list_item != null) {
			devices_list.select_row(list_item);
		}

		if (this.primary_stream != null) {
			this.primary_stream.disconnect(this.primary_notify_id);
			primary_notify_id = 0;
		}

		primary_notify_id = stream.notify.connect((n, p) => {
			if (p.name == "volume" || p.name == "is-muted") {
				update_volume();
			}
		});

		this.primary_stream = stream;
		update_volume();
		devices_list.queue_draw();
		devices_state_changed();
	}

	/**
	 * on_device_removed will handle when a Gvc.MixerUIDevice has been removed
	 */
	private void on_device_removed(uint id) {
		Gtk.ListBoxRow? list_item = devices.lookup(id);

		if (list_item == null) {
			return;
		}

		devices.steal(id);
		list_item.destroy();
		devices_list.queue_draw();
		devices_state_changed();
	}

	/**
	 * on_device_selected will handle when a checkbox related to an input or output device is selected
	 */
	private void on_device_selected(Gtk.ListBoxRow? list_item) {
		SignalHandler.block_by_func((void*)devices_list, (void*)on_device_selected, this);
		uint id = list_item.get_data("device_id");
		var device = mixer.lookup_input_id(id);

		if (device != null) {
			mixer.change_input(device);
		}
		SignalHandler.unblock_by_func((void*)devices_list, (void*)on_device_selected, this);
	}

	/**
	 * When our volume slider has changed
	 */
	private void on_scale_change() {
		if (primary_stream == null || primary_stream.get_is_muted()) {
			return;
		}

		if (primary_stream.set_volume((uint32)volume_slider.get_value())) {
			Gvc.push_volume(primary_stream);
		}
	}

	/**
	 * on_state_changed will handle when the state of our Mixer or its streams have changed
	 */
	private void on_state_changed(uint id) {
		devices_state_changed();
	}

	/**
	 * update_volume will handle updating our volume slider and output header during device change
	 */
	private void update_volume() {
		var vol = primary_stream.get_volume();
		var vol_max = mixer.get_vol_max_norm();

		/* Same maths as computed by volume.js in gnome-shell, carried over
		 * from C->Vala port of budgie-panel */
		int n = (int) Math.floor(3*vol/vol_max)+1;
		string image_name;

		// Work out an icon
		string icon_prefix = "microphone-sensitivity";

		if (primary_stream.get_is_muted() || vol <= 0) {
			image_name = "muted";
		} else {
			switch (n) {
				case 1:
					image_name = "low";
					break;
				case 2:
					image_name = "medium";
					break;
				default:
					image_name = "high";
					break;
			}
		}

		var header_image = (Gtk.Image?) header_icon.get_image();
		header_image.set_from_icon_name("%s-%s-symbolic".printf(icon_prefix, image_name), Gtk.IconSize.MENU);

		if (scale_id > 0) {
			SignalHandler.block(volume_slider, scale_id);
		}

		if (scale_id > 0) {
			SignalHandler.unblock(volume_slider, scale_id);
		}
	}

	/*
	 * set_slider_range_on_max will set the slider range based on whether or not we are allowing overdrive
	 */
	private void set_slider_range_on_max(bool allow_overdrive) {
		var current_volume = volume_slider.get_value();
		var vol_max = mixer.get_vol_max_norm();
		var vol_max_above = mixer.get_vol_max_amplified();
		var step_size = vol_max / 20;

		int slider_start = 0;
		int slider_end = 0;
		volume_slider.get_slider_range(out slider_start, out slider_end);

		if (allow_overdrive && (slider_end != vol_max_above)) { // If we're allowing higher than max and currently slider is not a max of 150
			volume_slider.set_increments(step_size, step_size);
			volume_slider.set_range(0, vol_max_above);
			volume_slider.set_value(current_volume);
		} else if (!allow_overdrive && (slider_end != vol_max)) { // If we're not allowing higher than max and slider is at max
			volume_slider.set_increments(step_size, step_size);
			volume_slider.set_range(0, vol_max);
			volume_slider.set_value(current_volume);
		}

		update_input_draw_markers();
	}

	/**
	 * update_input_draw_markers will update our draw markers
	 */
	private void update_input_draw_markers() {
		bool allow_higher_than_max = get_instance_settings().get_boolean("allow-volume-overdrive");

		if (allow_higher_than_max) { // If overdrive is enabled and thus should show mark
			var vol_max = mixer.get_vol_max_norm();
			volume_slider.add_mark(vol_max, Gtk.PositionType.BOTTOM, "");
		} else { // If we should not show markets
			volume_slider.clear_marks();
		}
	}

	private void settings_updated(string key) {
		if (key == "allow-volume-overdrive") {
			set_slider_range_on_max(get_instance_settings().get_boolean(key));
		}
	}

	public override Gtk.Widget build_settings_ui() {
		return new SoundInputRavenWidgetSettings(get_instance_settings());
	}
}

[GtkTemplate (ui="/org/buddiesofbudgie/budgie-desktop/raven/widget/SoundInput/settings.ui")]
public class SoundInputRavenWidgetSettings : Gtk.Grid {
	[GtkChild]
	private unowned Gtk.Switch? switch_allow_volume_overdrive;

	public SoundInputRavenWidgetSettings(Settings? settings) {
		settings.bind("allow-volume-overdrive", switch_allow_volume_overdrive, "active", SettingsBindFlags.DEFAULT);
	}
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
	// boilerplate - all modules need this
	var objmodule = module as Peas.ObjectModule;
	objmodule.register_extension_type(typeof(Budgie.RavenPlugin), typeof(SoundInputRavenPlugin));
}
