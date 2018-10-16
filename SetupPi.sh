update-locale "LANG=en_US.UTF-8"
locale-gen --purge "en_US.UTF-8"
dpkg-reconfigure --frontend noninteractive locales

cat >>~/.bashrc <<EOF
export LS_OPTIONS='--color=auto'
eval "\`dircolors\`"
alias ls='ls $$LS_OPTIONS'
alias ll='ls $$LS_OPTIONS -l'
alias l='ls $$LS_OPTIONS -lA'
export LANG=en_US.UTF-8
EOF
