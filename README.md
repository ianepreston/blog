# Blog

My blog, generated with [Quarto](https://quarto.org/).

## Local development with Nix

The flake supports Apple Silicon macOS, as well as x86-64 and ARM64 Linux.
After [installing Nix](https://nixos.org/download/), enter the development shell:

```sh
nix develop
```

Build the site into `_site/`:

```sh
quarto render
```

Start a local server with live reload and open the URL Quarto prints (normally
<http://localhost:4200/>):

```sh
quarto preview
```

You can also run either command without entering a persistent shell:

```sh
nix develop --command quarto render
nix develop --command quarto preview
```

If you use direnv, the checked-in `.envrc` enters the same flake automatically
after `direnv allow`.
