[
  {
    name = "/dev/null";
    type = "char";
    major = "1";
    minor = "3";
    mode = "rwm";
  }
  {
    name = "/dev/zero";
    type = "char";
    major = "1";
    minor = "5";
    mode = "rwm";
  }
  {
    name = "/dev/full";
    type = "char";
    major = "1";
    minor = "7";
    mode = "rwm";
  }
  {
    name = "/dev/random";
    type = "char";
    major = "1";
    minor = "8";
    mode = "rwm";
  }
  {
    name = "/dev/urandom";
    type = "char";
    major = "1";
    minor = "9";
    mode = "rwm";
  }
  {
    name = "/dev/kmsg";
    type = "char";
    major = "1";
    minor = "11";
    mode = "rwm";
  }
  {
    name = "/dev/tty";
    type = "char";
    major = "5";
    minor = "0";
    mode = "rwm";
  }
  {
    # name = "/dev/console"; # setup by LXC
    type = "char";
    major = "5";
    minor = "1";
    mode = "rwm";
  }
  {
    # name = "/dev/ptmx"; # setup by LXC
    type = "char";
    major = "5";
    minor = "2";
    mode = "rwm";
  }
  {
    # name = "/dev/tty*"; # setup by LXC
    type = "char";
    major = "136";
    minor = "*";
    mode = "rwm";
  }
  # Allow mknod for all devices
  {
    type = "block";
    major = "*";
    minor = "*";
    mode = "m";
  }
  {
    type = "char";
    major = "*";
    minor = "*";
    mode = "m";
  }
]
