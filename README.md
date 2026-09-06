# hub-deploy

Deployment resources for JupyterHub.

Deploys JupyterHub for BIDS-managed hubs,
such as Berkeley's AI Futures Lab.

## Tasks

### Adding and updating packages

The user image is managed in this repo in `images/user`.
The environment is (mostly) managed with [pixi],
so you can follow the pixi docs for various operations on the environment.
The image is built and published from GitHub Actions.

You can add packages to the image with:

```bash
cd images/user
pixi add "$package=*"
```

And you can update specific packages with:

```bash
pixi update $package
```

You can update _all_ packages in the image with:

```bash
pixi update
```

Any package update change must include updates to `pixi.lock`.
So if you edit `pixi.toml` by hand instead of the pixi command-line, you'll need to run `pixi lock` to update the lockfile.

[pixi]: https://pixi.prefix.dev
