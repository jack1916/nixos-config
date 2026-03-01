{ config, pkgs, inputs, ... }:

{
  imports = [
    inputs.kickstart-nixvim.homeManagerModules.default
  ];
  programs.nixvim.enable = true;

  programs.git = {
    enable = true;
  };
  home.username = "jack";
  home.homeDirectory = "/home/jack";
  home.stateVersion = "25.05";

  home.packages = with pkgs;[
  ripgrep
  fd

  tmux
  fzf
  bat

  gcc
  gnumake
  ];
  programs.tmux = {
    enable = true;
    clock24 = true;
    keyMode = "vi";
    mouse = true;
    
    # This sets the prefix to Ctrl+s
    prefix = "C-s";
    
    extraConfig = ''
      # Unbind the default prefix
      unbind C-b
      
      # Bind Ctrl+s as the new prefix
      bind C-s send-prefix
      
      # Custom keybindings for pane navigation
      bind-key h select-pane -L
      bind-key j select-pane -D
      bind-key k select-pane -U
      bind-key l select-pane -R
      
      # Status bar styling
      set -g status-style 'bg=#333333 fg=#5eacd3'
    '';
  };  
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
    defaultOptions = [ "--height 40%" "--layout=reverse" "--border" ];
  };
}
