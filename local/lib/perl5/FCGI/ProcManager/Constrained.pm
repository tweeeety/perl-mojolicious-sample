package FCGI::ProcManager::Constrained;
use strict;
use warnings;
use Carp qw/ confess /;
use base 'FCGI::ProcManager';
use Config;

sub new {
    my $proto = shift;
    my $self = $proto->SUPER::new(@_);
    $self->{max_requests} = $ENV{PM_MAX_REQUESTS} || 0 unless defined $self->{max_requests};
    $self->{sizecheck_num_requests} = $ENV{PM_SIZECHECK_NUM_REQUESTS} || 0 unless defined $self->{sizecheck_num_requests};
    $self->{max_size} = $ENV{PM_MAX_SIZE} || 0 unless defined $self->{max_size};
    if ($self->{sizecheck_num_requests} && ! _can_check_size()) {
        confess "Cannot load size check modules for your platform: sizecheck_num_requests > 0 unsupported";
    }
    return $self;
}

sub max_requests { shift->pm_parameter('max_requests', @_); }

sub sizecheck_num_requests { shift->pm_parameter('sizecheck_num_requests', @_); }

sub max_size { shift->pm_parameter('max_size', @_); }

sub handling_init {
    my $self = shift;
    $self->SUPER::handling_init();
    $self->{_request_counter} = 0;
}

sub pm_post_dispatch {
    my $self = shift;
    if ($self->max_requests > 0 && ++$self->{_request_counter} == $self->max_requests) {
        $self->pm_exit("safe exit after max_requests (" . $self->{_request_counter} . ")");
    }
    if ($self->sizecheck_num_requests
        and $self->{_request_counter} # Not the first request
        and $self->{_request_counter} % $self->sizecheck_num_requests == 0
    ) {
        $self->pm_exit("safe exit due to memory limits exceeded after " . $self->{_request_counter} . " requests")
            if $self->_limits_are_exceeded;
    }
    $self->SUPER::pm_post_dispatch();
}

sub _limits_are_exceeded {
    my $self = shift;

    my ($size, $share, $unshared) = $self->_check_size();

    return 1 if $self->max_size  && $size > $self->max_size;
    return 0 unless $share;
# FIXME
#    return 1 if $self->min_share_size    && $share < $self->min_share_size;
#    return 1 if $self->max_unshared_size && $unshared > $self->max_unshared_size;

    return 0;
}

# The following code is wholesale is nicked from Apache::SizeLimit::Core

sub _check_size {
    my $class = shift;

    my ($size, $share) = $class->_platform_check_size();

    return ($size, $share, $size - $share);
}

sub _load {
    my $mod = shift;
    $mod =~ s/::/\//g;
    $mod .= '.pm';
    eval { require($mod); 1; }
}
our $USE_SMAPS;
BEGIN {
    my ($major,$minor) = split(/\./, $Config{'osvers'});
    if ($Config{'osname'} eq 'solaris' &&
        (($major > 2) || ($major == 2 && $minor >= 6))) {
        *_can_check_size = sub () { 1 };
        *_platform_check_size   = \&_solaris_2_6_size_check;
        *_platform_getppid = \&_perl_getppid;
    }
    elsif ($Config{'osname'} eq 'linux' && _load('Linux::Pid')) {
        *_platform_getppid = \&_linux_getppid;
        *_can_check_size = sub () { 1 };
        if (_load('Linux::Smaps') && Linux::Smaps->new($$)) {
            $USE_SMAPS = 1;
            *_platform_check_size = \&_linux_smaps_size_check;
        }
        else {
            $USE_SMAPS = 0;
            *_platform_check_size = \&_linux_size_check;
        }
    }
    elsif ($Config{'osname'} =~ /(?:bsd|aix)/i && _load('BSD::Resource')) {
        # on OSX, getrusage() is returning 0 for proc & shared size.
        *_can_check_size = sub () { 1 };
        *_platform_check_size   = \&_bsd_size_check;
        *_platform_getppid = \&_perl_getppid;
    }
    else {
        *_can_check_size = sub () { 0 };
    }
}

sub _linux_smaps_size_check {
    my $class = shift;

    return $class->_linux_size_check() unless $USE_SMAPS;

    my $s = Linux::Smaps->new($$)->all;
    return ($s->size, $s->shared_clean + $s->shared_dirty);
}

sub _linux_size_check {
    my $class = shift;

    my ($size, $share) = (0, 0);
    if (open my $fh, '<', '/proc/self/statm') {
        ($size, $share) = (split /\s/, scalar <$fh>)[0,2];
        close $fh;
    }
    else {
        $class->_error_log("Fatal Error: couldn't access /proc/self/status");
    }

    # linux on intel x86 has 4KB page size...
    return ($size * 4, $share * 4);
}

sub _solaris_2_6_size_check {
    my $class = shift;

    my $size = -s "/proc/self/as"
        or $class->_error_log("Fatal Error: /proc/self/as doesn't exist or is empty");
    $size = int($size / 1024);

    # return 0 for share, to avoid undef warnings
    return ($size, 0);
}

# rss is in KB but ixrss is in BYTES.
# This is true on at least FreeBSD, OpenBSD, & NetBSD
sub _bsd_size_check {

    my @results = BSD::Resource::getrusage();
    my $max_rss   = $results[2];
    my $max_ixrss = int ( $results[3] / 1024 );

    return ($max_rss, $max_ixrss);
}

sub _win32_size_check {
    my $class = shift;

    # get handle on current process
    my $get_current_process = Win32::API->new(
        'kernel32',
        'get_current_process',
        [],
        'I'
    );
        my $proc = $get_current_process->Call();

    # memory usage is bundled up in ProcessMemoryCounters structure
    # populated by GetProcessMemoryInfo() win32 call
    my $DWORD  = 'B32';    # 32 bits
    my $SIZE_T = 'I';      # unsigned integer

    # build a buffer structure to populate
    my $pmem_struct = "$DWORD" x 2 . "$SIZE_T" x 8;
    my $mem_counters
        = pack( $pmem_struct, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

    # GetProcessMemoryInfo is in "psapi.dll"
    my $get_process_memory_info = new Win32::API(
        'psapi',
        'GetProcessMemoryInfo',
        [ 'I', 'P', 'I' ],
        'I'
    );

    my $bool = $get_process_memory_info->Call(
        $proc,
        $mem_counters,
        length $mem_counters,
    );

    # unpack ProcessMemoryCounters structure
    my $peak_working_set_size =
        (unpack($pmem_struct, $mem_counters))[2];

    # only care about peak working set size
    my $size = int($peak_working_set_size / 1024);

    return ($size, 0);
}

sub _perl_getppid { return getppid }
sub _linux_getppid { return Linux::Pid::getppid() }

1;

=head1 NAME

FCGI::ProcManager::Constrained - Process manager with constraints

=head1 SYNOPSIS

    $ENV{PM_MAX_REQUESTS} = 1000;
    $ENV{PM_SIZECHECK_NUM_REQUESTS} = 10;
    $ENV{PM_MAX_SIZE} = 4096;

=head1 DESCRIPTION

Subclass of L<FCGI::ProcManager> which adds checks for memory limits
like L<Apache::SizeLimit>.

=head1 AUTHORS, COPYRIGHT AND LICENSE

See L<FCGI::ProcManager>.

=cut

