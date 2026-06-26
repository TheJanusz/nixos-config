{ config, ... }: {
  age.secrets.authentik-env.file = ../../secrets/authentik-env.age;

  services.authentik = {
    enable = true;

    environmentFile = config.age.secrets.authentik-env.path;

    settings = {
      path = "/authentik/";
    };
  };
}
