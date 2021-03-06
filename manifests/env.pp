# This resource creates a build environment for a given release and architecture
# of FreeBSD. Passing in custom options gives you the ability to turn on and
# off certain features of your ports. Specific make options you would put in
# make.conf, you can pass here as well.
# Automatic periodic building of packages is managed with the cron_enable
# parameter
#
# @param version Version of the jail
# @param ensure The desired state of this environment
# @param makeopts Build options
# @param makefile Path to a Makefile
# @param arch Architecture of the jail
# @param jail Name of the jail
# @param paralleljobs Override the number of builders
# @param pkgs List of packages to build
# @param pkg_file Puppet path to a list of packages to build
# @param pkg_makeopts Per package build options
# @param pkg_optsdir Path to a directory of build options
# @param portstree The port tree to use
# @param cron_enable Enable automatic updates
# @param cron_always_mail Always send an e-mail on update
# @param cron_interval Scheduling of automatic updates
define poudriere::env (
  String[1]                      $version,
  Enum['present', 'absent']      $ensure           = 'present',
  Array[String[1]]               $makeopts         = [],
  Optional[String[1]]            $makefile         = undef,
  Optional[Poudriere::Architecture] $arch          = undef,
  String[1]                      $jail             = $name,
  Integer[1]                     $paralleljobs     = $facts['processors']['count'],
  Array[String[1]]               $pkgs             = [],
  Optional[Stdlib::Absolutepath] $pkg_file         = undef,
  Hash                           $pkg_makeopts     = {},
  Optional[Stdlib::Absolutepath] $pkg_optsdir      = undef,
  String[1]                      $portstree        = 'default',
  Boolean                        $cron_enable      = false,
  Boolean                        $cron_always_mail = false,
  Poudriere::Cron_interval       $cron_interval    = { minute => 0, hour => 0, monthday => '*', month => '*', weekday => '*' },
) {
  # Make sure we are prepared to run
  include poudriere

  if $makefile and ($makeopts.length() > 0 or $pkg_makeopts.length() > 0) {
    fail("\$makefile cannot be combined with \$makeopts and \$pkg_makeopts")
  }

  if $facts['os']['architecture'] == 'amd64' and $arch and $arch !~ 'amd64' and $arch !~ 'i386' {
    include poudriere::xbuild
  }

  if ! defined(Poudriere::Portstree[$portstree]) {
    if $portstree == 'defaut' {
      warning('The default portstree is no longer created automatically.  Please consult the Readme file for instructions on how to create this yourself')
    } else {
      warning("portstree['${portstree}'] is not defined please consult the Readme for instructions on how to create this.")
    }
  }

  $manage_file_ensure = $ensure ? {
    'absent' => 'absent',
    default  => 'file',
  }

  $manage_directory_ensure = $ensure ? {
    'absent' => 'absent',
    default  => 'directory',
  }

  # NOTE: directory cannot be defined absent
  # with recurse => true at the sime time:
  # https://tickets.puppetlabs.com/browse/PUP-2903
  $manage_directory_recurse = $ensure ? {
    'absent' => false,
    default  => true,
  }

  $manage_cron_ensure = $ensure ? {
    'absent' => 'absent',
    default => $cron_enable ? {
      true => 'present',
      default => 'absent',
    },
  }

  # Manage jail
  if $ensure != 'absent' {
    $arch_arg = $arch ? {
      Undef   => '',
      default => "-a ${arch}",
    }
    exec { "poudriere-jail-${jail}":
      command => "/usr/local/bin/poudriere jail -c -j ${jail} -v ${version} ${arch_arg} -p ${portstree}",
      require => Poudriere::Portstree[$portstree],
      creates => regsubst("${poudriere::poudriere_base}/jails/${jail}/", ':', '_', 'G'),
      timeout => 3600,
    }
  } else {
    exec { "poudriere-jail-${jail}":
      command => "/usr/local/bin/poudriere jail -d -j ${jail}",
      onlyif  => "/usr/local/bin/poudriere jail -l | /usr/bin/grep -w '^${jail}'",
    }
  }

  # Lay down the configuration
  file { "/usr/local/etc/poudriere.d/${jail}-make.conf":
    ensure  => $manage_file_ensure,
    source  => $makefile,
    content => if $makefile { undef } else { epp('poudriere/make.conf', { makeopts => $makeopts, pkg_makeopts => $pkg_makeopts }) },
    require => Exec["poudriere-jail-${jail}"],
  }

  # Define list of packages to build
  file { "/usr/local/etc/poudriere.d/${jail}.list":
    ensure  => $manage_file_ensure,
    source  => $pkg_file,
    content => inline_template("<%= (@pkgs.join('\n'))+\"\n\" %>"),
    require => Exec["poudriere-jail-${jail}"],
  }

  # Define optional port building options
  if $pkg_optsdir {
    file { "/usr/local/etc/poudriere.d/${jail}-options/":
      ensure  => $manage_directory_ensure,
      recurse => $manage_directory_recurse,
      force   => true,
      source  => $pkg_optsdir,
      require => Exec["poudriere-jail-${jail}"],
    }
  }

  if $cron_always_mail {
    $cron_command = "poudriere bulk -f /usr/local/etc/poudriere.d/${jail}.list -j ${jail} -J ${paralleljobs} -p ${portstree}"
  } else {
    $cron_command = "OUTPUT=\$(poudriere bulk -f /usr/local/etc/poudriere.d/${jail}.list -j ${jail} -J ${paralleljobs} -p ${portstree}) || echo \${OUTPUT}"
  }
  # Build new ports periodically
  cron { "poudriere-bulk-${jail}":
    ensure   => $manage_cron_ensure,
    command  => $cron_command,
    user     => 'root',
    minute   => $cron_interval['minute'],
    hour     => $cron_interval['hour'],
    monthday => $cron_interval['monthday'],
    month    => $cron_interval['month'],
    weekday  => $cron_interval['weekday'],
    require  => Exec["poudriere-jail-${jail}"],
  }
}
