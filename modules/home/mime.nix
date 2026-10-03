{ ... }:
{
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/*" = "nvim.desktop";
      "text/html" = "brave-browser.desktop";
      "application/xhtml+xml" = "brave-browser.desktop";
      "application/json" = "nvim.desktop";
      "application/javascript" = "nvim.desktop";
      "application/xml" = "nvim.desktop";
      "application/x-shellscript" = "nvim.desktop";

      "image/*" = "gimp.desktop";
      "image/svg+xml" = "org.inkscape.Inkscape.desktop";

      "audio/*" = "vlc.desktop";
      "video/*" = "vlc.desktop";
      "application/pdf" = "brave-browser.desktop";

      "inode/directory" = "org.gnome.Nautilus.desktop";

      "x-scheme-handler/http" = "brave-browser.desktop";
      "x-scheme-handler/https" = "brave-browser.desktop";
      "x-scheme-handler/tg" = "org.telegram.desktop.desktop";
      "x-scheme-handler/tonsite" = "org.telegram.desktop.desktop";
      "x-scheme-handler/freetube" = "freetube.desktop";
      "x-scheme-handler/fluxer" = "fluxer-canary.desktop";

      "application/msword" = "writer.desktop";
      "application/vnd.ms-excel" = "calc.desktop";
      "application/vnd.ms-powerpoint" = "impress.desktop";
      "application/vnd.oasis.opendocument.text" = "writer.desktop";
      "application/vnd.oasis.opendocument.spreadsheet" = "calc.desktop";
      "application/vnd.oasis.opendocument.presentation" = "impress.desktop";
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "writer.desktop";
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "calc.desktop";
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "impress.desktop";
    };
  };
}
