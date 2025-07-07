# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
# --
# $origin: otobo - c14ca55a8b1d3d686e803c1398813b83d22091e5 - Kernel/System/MailAccount.pm
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::System::MailAccount;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DB',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::Valid',
    'Kernel::System::Cache',
# Rother OSS / xoauth2
    'Kernel::System::OpenIDConnect::FunctionalAccounts',
# EO xoauth2
);

=head1 NAME

Kernel::System::MailAccount - to manage mail accounts

=head1 DESCRIPTION

All functions to manage the mail accounts.

=head1 PUBLIC INTERFACE

=head2 new()

Don't use the constructor directly, use the ObjectManager instead:

    my $MailAccountObject = $Kernel::OM->Get('Kernel::System::MailAccount');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    $Self->{CacheType} = 'MailAccount';
    $Self->{CacheTTL}  = 60 * 60 * 24 * 20;    # 20 days

    return $Self;
}

=head2 MailAccountAdd()

adds a new mail account

    $MailAccount->MailAccountAdd(
        Login         => 'mail',
        Password      => 'SomePassword',
        Host          => 'pop3.example.com',
        Type          => 'POP3',
        IMAPFolder    => 'Some Folder', # optional, only valid for IMAP-type accounts
        ValidID       => 1,
        Trusted       => 0,
        DispatchingBy => 'Queue', # Queue|From
        QueueID       => 12,
        UserID        => 123,
# Rother OSS / xoauth2
        Auth          => Basic|XOAUTH2|OAUTHBEARER # optional, defaults to Basic
        AccountName   => FunctionalAccount Name    # mandatory if auth ne Basic
# EO xoauth2
    );

=cut

sub MailAccountAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
# Rother OSS / xoauth2
#   for (qw(Login Password Host ValidID Trusted DispatchingBy QueueID UserID)) {
    for (qw(Login Host ValidID Trusted DispatchingBy QueueID UserID)) {
# EO xoauth2
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "$_ not defined!"
            );
            return;
        }
    }

# Rother OSS / xoauth2
#   for (qw(Login Password Host Type ValidID UserID)) {
    for (qw(Login Host Type ValidID UserID)) {
# EO xoauth2
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

# Rother OSS / xoauth2
    my $AuthType = $Param{'Auth'} || 'Basic';
    my $OAuth2AccountID;
    if ( $AuthType ne 'Basic' ) {

        $OAuth2AccountID = $Self->_GetOIDCAccountID(%Param);

        return if !$OAuth2AccountID;

        $Param{Password} = '';
    }
    else {
        if ( !$Param{Password} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need Password!"
            );
            return;
        }        
    }
# EO xoauth2

    # check if dispatching is by From
    if ( $Param{DispatchingBy} eq 'From' ) {
        $Param{QueueID} = 0;
    }
    elsif ( $Param{DispatchingBy} eq 'Queue' && !$Param{QueueID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need QueueID for dispatching!"
        );
        return;
    }

    # only set IMAP folder on IMAP type accounts
    # fallback to 'INBOX' if none given
    if ( $Param{Type} =~ m{ IMAP .* }xmsi ) {
        if ( !defined $Param{IMAPFolder} || !$Param{IMAPFolder} ) {
            $Param{IMAPFolder} = 'INBOX';
        }
    }
    else {
        $Param{IMAPFolder} = '';
    }

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # sql
    return if !$DBObject->Do(
        SQL =>
            'INSERT INTO mail_account (login, pw, host, account_type, valid_id, comments, queue_id, '

# Rother OSS / xoauth2
#           . ' imap_folder, trusted, create_time, create_by, change_time, change_by )'
#           . ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, current_timestamp, ?, current_timestamp, ?)',
            . ' imap_folder, trusted, create_time, create_by, change_time, change_by, auth, functional_account_id)'
            . ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, current_timestamp, ?, current_timestamp, ?, ?, ?)',
# EO xoauth2
        Bind => [
            \$Param{Login},   \$Param{Password}, \$Param{Host},    \$Param{Type},
            \$Param{ValidID}, \$Param{Comment},  \$Param{QueueID}, \$Param{IMAPFolder},
# Rother OSS / xoauth2
#           \$Param{Trusted}, \$Param{UserID},   \$Param{UserID},
            \$Param{Trusted}, \$Param{UserID}, \$Param{UserID}, \$AuthType, \$OAuth2AccountID
# EO xoauth2
        ],
    );

    # delete cache
    $Kernel::OM->Get('Kernel::System::Cache')->CleanUp(
        Type => $Self->{CacheType},
    );

    return if !$DBObject->Prepare(
# Rother OSS / xoauth2
#        SQL  => 'SELECT id FROM mail_account WHERE login = ? AND host = ? AND account_type = ? ',
#        Bind => [ \$Param{Login}, \$Param{Host}, \$Param{Type} ],
        SQL  => 'SELECT id FROM mail_account WHERE login = ? AND host = ? AND account_type = ? AND auth = ? ',
        Bind => [ \$Param{Login}, \$Param{Host}, \$Param{Type}, \$AuthType ],
# EO xoauth2
    );

    my $ID;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ID = $Row[0];
    }

    return $ID;
}

=head2 MailAccountGetAll()

returns an array of all mail account data

    my @MailAccounts = $MailAccount->MailAccountGetAll();

# Rother OSS / xoauth2
# (returns list of the fields for each account: ID, Login, Password, Host, Type, QueueID, Trusted, IMAPFolder, Comment, DispatchingBy, ValidID )
(returns list of the fields for each account: ID, Login, Password, Host, Type, QueueID, Trusted, IMAPFolder, Comment, DispatchingBy, ValidID, Auth, FunctionalAccountName )
# EO xoauth2


=cut

sub MailAccountGetAll {
    my ( $Self, %Param ) = @_;

    # check cache
    my $CacheKey = 'MailAccountGetAll';
    my $Cache    = $Kernel::OM->Get('Kernel::System::Cache')->Get(
        Type => $Self->{CacheType},
        Key  => $CacheKey,
    );
    return @{$Cache} if $Cache;

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # sql
    return if !$DBObject->Prepare(
        SQL =>

# Rother OSS / xoauth2
#             'SELECT id, login, pw, host, account_type, queue_id, imap_folder, trusted, comments, valid_id, '
#             . ' create_time, change_time FROM mail_account',
            'SELECT ma.id, ma.login, ma.pw, ma.host, ma.account_type, ma.queue_id, ma.imap_folder, ma.trusted, ma.comments, ma.valid_id, '
            . ' ma.create_time, ma.change_time, ma.auth, ofa.name '
            . ' FROM mail_account ma '
            . ' LEFT JOIN oidc_functional_accounts ofa ON ma.functional_account_id = ofa.id '
# EO xoauth2
    );

    my @Accounts;
    while ( my @Data = $DBObject->FetchrowArray() ) {
        my %Data = (
            ID         => $Data[0],
            Login      => $Data[1],
            Password   => $Data[2],
            Host       => $Data[3],
            Type       => $Data[4] || 'POP3',    # compat for old setups
            QueueID    => $Data[5],
            IMAPFolder => $Data[6],
            Trusted    => $Data[7],
            Comment    => $Data[8],
            ValidID    => $Data[9],
            CreateTime => $Data[10],
            ChangeTime => $Data[11],
# Rother OSS / xoauth2
            Auth        => $Data[12],
            AccountName => $Data[13],
# EO xoauth2
        );

        if ( $Data{QueueID} == 0 ) {
            $Data{DispatchingBy} = 'From';
        }
        else {
            $Data{DispatchingBy} = 'Queue';
        }

        # only return IMAP folder on IMAP type accounts
        # fallback to 'INBOX' if none given
        if ( $Data{Type} =~ m{ IMAP .* }xmsi ) {
            if ( defined $Data{IMAPFolder} && !$Data{IMAPFolder} ) {
                $Data{IMAPFolder} = 'INBOX';
            }
        }
        else {
            $Data{IMAPFolder} = '';
        }

        push @Accounts, \%Data;
    }

    # set cache
    $Kernel::OM->Get('Kernel::System::Cache')->Set(
        Type  => $Self->{CacheType},
        TTL   => $Self->{CacheTTL},
        Key   => $CacheKey,
        Value => \@Accounts,
    );

    return @Accounts;
}

=head2 MailAccountGet()

returns a hash of mail account data

    my %MailAccount = $MailAccount->MailAccountGet(
        ID => 123,
    );

(returns: ID, Login, Password, Host, Type, QueueID, Trusted, IMAPFolder, Comment, DispatchingBy, ValidID)

=cut

sub MailAccountGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need ID!"
        );
        return;
    }

    # check cache
    my $CacheKey = join '::', 'MailAccountGet', 'ID', $Param{ID};
    my $Cache    = $Kernel::OM->Get('Kernel::System::Cache')->Get(
        Type => $Self->{CacheType},
        Key  => $CacheKey,
    );
    return %{$Cache} if $Cache;

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # sql
    return if !$DBObject->Prepare(
        SQL =>

# Rother OSS / xoau6th2
#            'SELECT login, pw, host, account_type, queue_id, imap_folder, trusted, comments, valid_id, '
#            . ' create_time, change_time FROM mail_account WHERE id = ?',
            'SELECT ma.login, ma.pw, ma.host, ma.account_type, ma.queue_id, ma.imap_folder, ma.trusted, ma.comments, ma.valid_id, '
            . ' ma.create_time, ma.change_time, ma.auth, ofa.name '
            . ' FROM mail_account ma '
            . ' LEFT JOIN oidc_functional_accounts ofa ON ma.functional_account_id = ofa.id '
            . '  WHERE ma.id = ?',
# EO exoauth2
        Bind => [ \$Param{ID} ],
    );

    my %Data;
    while ( my @Data = $DBObject->FetchrowArray() ) {
        %Data = (
            ID         => $Param{ID},
            Login      => $Data[0],
            Password   => $Data[1],
            Host       => $Data[2],
            Type       => $Data[3] || 'POP3',    # compat for old setups
            QueueID    => $Data[4],
            IMAPFolder => $Data[5],
            Trusted    => $Data[6],
            Comment    => $Data[7],
            ValidID    => $Data[8],
            CreateTime => $Data[9],
            ChangeTime => $Data[10],
# Rother OSS / xoauth2
            Auth        => $Data[11],
            AccountName => $Data[12],
# EO xoauth2
        );
    }

    if ( $Data{QueueID} == 0 ) {
        $Data{DispatchingBy} = 'From';
    }
    else {
        $Data{DispatchingBy} = 'Queue';
    }

    # only return IMAP folder on IMAP type accounts
    # fallback to 'INBOX' if none given
    if ( $Data{Type} =~ m{ IMAP .* }xmsi ) {
        if ( defined $Data{IMAPFolder} && !$Data{IMAPFolder} ) {
            $Data{IMAPFolder} = 'INBOX';
        }
    }
    else {
        $Data{IMAPFolder} = '';
    }

    # set cache
    $Kernel::OM->Get('Kernel::System::Cache')->Set(
        Type  => $Self->{CacheType},
        TTL   => $Self->{CacheTTL},
        Key   => $CacheKey,
        Value => \%Data,
    );

    return %Data;
}

=head2 MailAccountUpdate()

update a new mail account

    $MailAccount->MailAccountUpdate(
        ID            => 1,
        Login         => 'mail',
        Password      => 'SomePassword',
        Host          => 'pop3.example.com',
        Type          => 'POP3',
        IMAPFolder    => 'Some Folder', # optional, only valid for IMAP-type accounts
        ValidID       => 1,
        Trusted       => 0,
        DispatchingBy => 'Queue', # Queue|From
        QueueID       => 12,
        UserID        => 123,
# Rother OSS / xoauth2
        Auth          => Basic|XOAUTH2|OAUTHBEARER # optional, defaults to Basic
        AccountName   => FunctionalAccount Name    # mandatory if auth ne Basic
# EO xoauth2
    );

=cut

sub MailAccountUpdate {
    my ( $Self, %Param ) = @_;

    # check needed stuff

# Rother OSS / xoauth2
#   for (qw(ID Login Password Host Type ValidID Trusted DispatchingBy QueueID UserID)) {
    for (qw(ID Login Host Type ValidID Trusted DispatchingBy QueueID UserID)) {
# EO xoauth2
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

# Rother OSS / xoauth2
    my $AuthType = $Param{'Auth'} || 'Basic';
    my $OAuth2AccountID;
    if ( $AuthType ne 'Basic' ) {

        $OAuth2AccountID = $Self->_GetOIDCAccountID(%Param);

        return if !$OAuth2AccountID;

        $Param{Password} = '';
    }
    else {

        if ( !$Param{Password} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need Password!"
            );
            return;
        }
    }
# EO xoauth2

    # check if dispatching is by From
    if ( $Param{DispatchingBy} eq 'From' ) {
        $Param{QueueID} = 0;
    }
    elsif ( $Param{DispatchingBy} eq 'Queue' && !$Param{QueueID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need QueueID for dispatching!"
        );
        return;
    }

    # only set IMAP folder on IMAP type accounts
    # fallback to 'INBOX' if none given
    if ( $Param{Type} =~ m{ IMAP .* }xmsi ) {
        if ( !defined $Param{IMAPFolder} || !$Param{IMAPFolder} ) {
            $Param{IMAPFolder} = 'INBOX';
        }
    }
    else {
        $Param{IMAPFolder} = '';
    }

    # sql
    return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
        SQL => 'UPDATE mail_account SET login = ?, pw = ?, host = ?, account_type = ?, '
            . ' comments = ?, imap_folder = ?, trusted = ?, valid_id = ?, change_time = current_timestamp, '
# Rother OSS / xoauth2
#           . ' change_by = ?, queue_id = ? WHERE id = ?',
            . ' change_by = ?, queue_id = ?, auth = ?, functional_account_id = ? WHERE id = ?',
# EO xoauth2
        Bind => [
            \$Param{Login},   \$Param{Password},   \$Param{Host},    \$Param{Type},
            \$Param{Comment}, \$Param{IMAPFolder}, \$Param{Trusted}, \$Param{ValidID},
# Rother OSS / xoauth2
#           \$Param{UserID},  \$Param{QueueID},  \$Param{ID},
            \$Param{UserID}, \$Param{QueueID}, \$AuthType, \$OAuth2AccountID, \$Param{ID},
# EO xoauth2
        ],
    );

    # delete cache
    $Kernel::OM->Get('Kernel::System::Cache')->CleanUp(
        Type => $Self->{CacheType},
    );

    return 1;
}

=head2 MailAccountDelete()

deletes a mail account

    $MailAccount->MailAccountDelete(
        ID => 123,
    );

=cut

sub MailAccountDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need ID!"
        );
        return;
    }

    # sql
    return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
        SQL  => 'DELETE FROM mail_account WHERE id = ?',
        Bind => [ \$Param{ID} ],
    );

    # delete cache
    $Kernel::OM->Get('Kernel::System::Cache')->CleanUp(
        Type => $Self->{CacheType},
    );

    return 1;
}

=head2 MailAccountList()

returns a list (Key, Name) of all mail accounts

    my %List = $MailAccount->MailAccountList(
        Valid => 0, # just valid/all accounts
    );

=cut

sub MailAccountList {
    my ( $Self, %Param ) = @_;

    # check cache
    my $CacheKey = join '::', 'MailAccountList', ( $Param{Valid} ? 'Valid::1' : '' );
    my $Cache    = $Kernel::OM->Get('Kernel::System::Cache')->Get(
        Type => $Self->{CacheType},
        Key  => $CacheKey,
    );
    return %{$Cache} if $Cache;

    # get valid object
    my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');

    my $Where = $Param{Valid}
        ? 'WHERE valid_id IN ( ' . join ', ', $ValidObject->ValidIDsGet() . ' )'
        : '';

    # get database object
    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    return if !$DBObject->Prepare(
        SQL => "SELECT id, host, login FROM mail_account $Where",
    );

    my %Data;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $Data{ $Row[0] } = "$Row[1] ($Row[2])";
    }

    # set cache
    $Kernel::OM->Get('Kernel::System::Cache')->Set(
        Type  => $Self->{CacheType},
        TTL   => $Self->{CacheTTL},
        Key   => $CacheKey,
        Value => \%Data,
    );

    return %Data;
}

=head2 MailAccountBackendList()

returns a list of usable backends

    my %List = $MailAccount->MailAccountBackendList();

=cut

sub MailAccountBackendList {
    my ( $Self, %Param ) = @_;

    my $Directory = $Kernel::OM->Get('Kernel::Config')->Get('Home') . '/Kernel/System/MailAccount/';

    my @List = $Kernel::OM->Get('Kernel::System::Main')->DirectoryRead(
        Directory => $Directory,
        Filter    => '*.pm',
    );

    my %Backends;
    for my $File (@List) {

        # remove .pm
        $File =~ s/^.*\/(.+?)\.pm$/$1/;
        my $GenericModule = "Kernel::System::MailAccount::$File";

        # try to load module $GenericModule
        if ( eval "require $GenericModule" ) {    ## no critic qw(BuiltinFunctions::ProhibitStringyEval)
            if ( eval { $GenericModule->new() } ) {
                $Backends{$File} = $File;
            }
        }
    }

    return %Backends;
}

=head2 MailAccountFetch()

fetch emails by using backend

    my $Ok = $MailAccount->MailAccountFetch(
        Login         => 'mail',
        Password      => 'SomePassword',
        Host          => 'pop3.example.com',
        Type          => 'POP3', # POP3,POP3s,IMAP,IMAPS
        Trusted       => 0,
        DispatchingBy => 'Queue', # Queue|From
        QueueID       => 12,
        UserID        => 123,
# Rother OSS / xoauth2
        Auth          => Basic|XOAUTH2|OAUTHBEARER     # optional, defaults to 'Basic'
        AccountName   => 'OIDC FunctionalAccount Name' # mandatory if Auth ne Basic
# EO xoauth2
    );

=cut

sub MailAccountFetch {
    my ( $Self, %Param ) = @_;

    # check needed stuff
# Rother OSS / xoauth2
#   for (qw(Login Password Host Type Trusted DispatchingBy QueueID UserID)) {
    for (qw(Login Host Type Trusted DispatchingBy QueueID UserID)) {
# EO xoauth2
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

# Rother OSS / xoauth2
    $Param{Auth} = $Param{Auth} || 'Basic';
    if ( $Param{Auth} ne 'Basic' ) {

        if ( $Param{Auth} ne 'XOAUTH2' && $Param{Auth} ne 'OAUTHBEARER' ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Auth type param must be one of 'Basic', 'XOAUTH2' or 'OAUTHBEARER' !"
            );
            return;
        }

        if ( !$Param{AccountName} ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Auth types 'XOAUTH2' and 'OAUTHBEARER' need Functional 'AccountName' param!"
            );
            return;
        }
    }
# EO xoauth2

    # load backend
    my $GenericModule = "Kernel::System::MailAccount::$Param{Type}";

    # try to load module $GenericModule
    return unless $Kernel::OM->Get('Kernel::System::Main')->Require($GenericModule);

    # fetch mails
    my $Backend = $GenericModule->new();

    return $Backend->Fetch(%Param);
}

=head2 MailAccountCheck()

Check inbound mail configuration

    my %Check = $MailAccount->MailAccountCheck(
        Login         => 'mail',
        Password      => 'SomePassword',
        Host          => 'pop3.example.com',
        Type          => 'POP3', # POP3|POP3S|IMAP|IMAPS
        Timeout       => '60',
        Debug         => '0',
    );

=cut

sub MailAccountCheck {
    my ( $Self, %Param ) = @_;

    # check needed stuff
# Rother OSS / xoauth2
#    for (qw(Login Password Host Type Timeout Debug)) {
    for (qw(Login Host Type Timeout Debug)) {
# EO xoauth2
        if ( !defined $Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

# Rother OSS / xoauth2
    $Param{Auth} = $Param{Auth} || 'Basic';
    if ( $Param{Auth} ne 'Basic' ) {

        if ( $Param{Auth} ne 'XOAUTH2' && $Param{Auth} ne 'OAUTHBEARER' ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Auth type param must be one of 'Basic', 'XOAUTH2' or 'OAUTHBEARER' !"
            );
            return;
        }

        if ( !$Param{AccountName} ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Auth types 'XOAUTH2' and 'OAUTHBEARER' need Functional 'AccountName' param!"
            );
            return;
        }
    }
# EO xoauth2

    # load backend
    my $GenericModule = "Kernel::System::MailAccount::$Param{Type}";

    # try to load module $GenericModule
    if ( !$Kernel::OM->Get('Kernel::System::Main')->Require($GenericModule) ) {
        return;
    }

    # check if connect is successful
    my $Backend = $GenericModule->new();
    my %Check   = $Backend->Connect(%Param);

    if ( $Check{Successful} ) {
        return ( Successful => 1 );
    }
    else {
        return (
            Successful => 0,
            Message    => $Check{Message}
        );
    }
}

# Rother OSS / xoauth2

sub _GetOIDCAccountID {

    my ( $Self, %Param ) = @_;

    my $AuthType = $Param{'Auth'};

    if ( $AuthType ne 'XOAUTH2' && $AuthType ne 'OAUTHBEARER' ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Auth type param must be one of 'Basic', 'XOAUTH2' or 'OAUTHBEARER' !"
        );
        return;
    }

    if ( !$Param{AccountName} ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Auth types 'XOAUTH2' and 'OAUTHBEARER' need Functional 'AccountName' param!"
        );
        return;
    }

    my $FunctionalAccountsObject = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts');

    my $OAuth2Account = $FunctionalAccountsObject->GetAccount(
        Name => $Param{AccountName}
    );

    if ( !$OAuth2Account ) {

        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "FunctionalAccount $Param{AccountName} not found for auth type $AuthType!",
        );
        return;
    }

    return $OAuth2Account->{AccountID};
}

# EO xoauth2

1;
