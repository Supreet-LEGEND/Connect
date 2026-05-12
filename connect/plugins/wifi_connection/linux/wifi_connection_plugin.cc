#include "include/wifi_connection/wifi_connection_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#include "wifi_connection_plugin_private.h"

// -------------------------
//   Helper: Check Wi-Fi Enabled Status
// -------------------------

bool is_wifi_enabled()
{
  GError *error = nullptr;

  GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
  if (!connection)
    return false;

  GVariant *result = g_dbus_connection_call_sync(
      connection,
      "org.freedesktop.NetworkManager",
      "/org/freedesktop/NetworkManager",
      "org.freedesktop.DBus.Properties",
      "Get",
      g_variant_new("(ss)", "org.freedesktop.NetworkManager", "WirelessEnabled"),
      G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE,
      -1,
      NULL,
      &error);

  if (!result)
    return false;

  GVariant *inner = nullptr;
  g_variant_get(result, "(v)", &inner);

  bool enabled = g_variant_get_boolean(inner);

  g_variant_unref(inner);
  g_variant_unref(result);
  return enabled;
}

// -------------------------
//   Helper: Open Wi-Fi Settings
// -------------------------

void open_wifi_settings()
{
  // GNOME-first approach
  system("gnome-control-center wifi &");

  // Fallback
  system("nm-connection-editor &");
}

// -------------------------
//   Helper: Get Access Points
// -------------------------

FlValue *get_wifi_networks()
{
  FlValue *list = fl_value_new_list();
  GError *error = NULL;

  GDBusConnection *conn = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
  if (!conn)
    return list;

  // Get all network devices
  GVariant *dev_list = g_dbus_connection_call_sync(
      conn,
      "org.freedesktop.NetworkManager",
      "/org/freedesktop/NetworkManager",
      "org.freedesktop.NetworkManager",
      "GetDevices",
      NULL,
      G_VARIANT_TYPE("(ao)"),
      G_DBUS_CALL_FLAGS_NONE,
      -1,
      NULL,
      &error);

  if (!dev_list)
    return list;

  GVariantIter *iter;
  g_variant_get(dev_list, "(ao)", &iter);

  const char *dev_path;
  while (g_variant_iter_loop(iter, "o", &dev_path))
  {
    // Check device type
    GVariant *type_var = g_dbus_connection_call_sync(
        conn,
        "org.freedesktop.NetworkManager",
        dev_path,
        "org.freedesktop.DBus.Properties",
        "Get",
        g_variant_new("(ss)", "org.freedesktop.NetworkManager.Device", "DeviceType"),
        G_VARIANT_TYPE("(v)"),
        G_DBUS_CALL_FLAGS_NONE,
        -1, NULL, &error);

    if (!type_var)
      continue;

    GVariant *inner;
    g_variant_get(type_var, "(v)", &inner);
    int dev_type = g_variant_get_uint32(inner);
    g_variant_unref(inner);
    g_variant_unref(type_var);

    // Wi-Fi type = 2
    if (dev_type != 2)
      continue;

    // Get AP list
    GVariant *aps = g_dbus_connection_call_sync(
        conn,
        "org.freedesktop.NetworkManager",
        dev_path,
        "org.freedesktop.NetworkManager.Device.Wireless",
        "GetAccessPoints",
        NULL,
        G_VARIANT_TYPE("(ao)"),
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        NULL,
        &error);

    if (!aps)
      continue;

    GVariantIter *ap_iter;
    g_variant_get(aps, "(ao)", &ap_iter);

    const char *ap_path;
    while (g_variant_iter_loop(ap_iter, "o", &ap_path))
    {
      GVariant *ssid_var = g_dbus_connection_call_sync(
          conn,
          "org.freedesktop.NetworkManager",
          ap_path,
          "org.freedesktop.DBus.Properties",
          "Get",
          g_variant_new("(ss)", "org.freedesktop.NetworkManager.AccessPoint", "Ssid"),
          G_VARIANT_TYPE("(v)"),
          G_DBUS_CALL_FLAGS_NONE,
          -1,
          NULL,
          &error);

      if (!ssid_var)
        continue;

      GVariant *ssid_inner;
      g_variant_get(ssid_var, "(v)", &ssid_inner);

      gsize len;
      const guint8 *ssid_bytes = g_variant_get_fixed_array(ssid_inner, &len, sizeof(guint8));

      char ssid[256] = {0};
      memcpy(ssid, ssid_bytes, len);

      fl_value_append_take(list, fl_value_new_string(ssid));

      g_variant_unref(ssid_inner);
      g_variant_unref(ssid_var);
    }

    g_variant_iter_free(ap_iter);
    g_variant_unref(aps);
  }

  g_variant_iter_free(iter);
  g_variant_unref(dev_list);

  return list;
}

// ---------------------------------------------------------------------

#define WIFI_CONNECTION_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), wifi_connection_plugin_get_type(), \
                              WifiConnectionPlugin))

struct _WifiConnectionPlugin
{
  GObject parent_instance;
};

G_DEFINE_TYPE(WifiConnectionPlugin, wifi_connection_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void wifi_connection_plugin_handle_method_call(
    WifiConnectionPlugin *self,
    FlMethodCall *method_call)
{
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0)
  {
    response = get_platform_version();
  }

  if (strcmp(method, "isWifiEnabled") == 0)
  {
    bool enabled = is_wifi_enabled();
    fl_method_call_respond_success(method_call, fl_value_new_bool(enabled), NULL);
    return;
  }

  if (strcmp(method, "openWifiSettings") == 0)
  {
    open_wifi_settings();
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "getWifiNetworks") == 0)
  {
    FlValue *networks = get_wifi_networks();
    fl_method_call_respond_success(method_call, networks, NULL);
    return;
  }

  else
  {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse *get_platform_version()
{
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void wifi_connection_plugin_dispose(GObject *object)
{
  G_OBJECT_CLASS(wifi_connection_plugin_parent_class)->dispose(object);
}

static void wifi_connection_plugin_class_init(WifiConnectionPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = wifi_connection_plugin_dispose;
}

static void wifi_connection_plugin_init(WifiConnectionPlugin *self) {}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  WifiConnectionPlugin *plugin = WIFI_CONNECTION_PLUGIN(user_data);
  wifi_connection_plugin_handle_method_call(plugin, method_call);
}

void wifi_connection_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  WifiConnectionPlugin *plugin = WIFI_CONNECTION_PLUGIN(
      g_object_new(wifi_connection_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "wifi_connection",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
