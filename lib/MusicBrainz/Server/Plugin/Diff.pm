package MusicBrainz::Server::Plugin::Diff;

use strict;
use warnings;

use feature 'switch';

use base 'Template::Plugin';

use Algorithm::Diff qw( sdiff traverse_sequences );
use Digest::MD5 qw( md5_hex );
use Encode;
use HTML::Tiny;
use HTML::TreeBuilder;
use Scalar::Util qw( blessed );
use MusicBrainz::Server::Translation qw( l );
use MusicBrainz::Server::Validation qw( encode_entities trim_in_place );

no if $] >= 5.018, warnings => "experimental::smartmatch";

sub new {
    my ($class, $context) = @_;
    return bless { c => $context }, $class;
}

sub uri_for_action {
    my $self = shift;
    return $self->{c}{STASH}{c}->uri_for_action(@_)->as_string;
}

my $TOKEN_NEW_PARA = chr(10);

my %class_map = (
    '+' => 'diff-only-b',
    '-' => 'diff-only-a'
);

my $h = HTML::Tiny->new;

sub diff_side {
    my ($self, $old, $new, $filter, $split) = @_;
    $split //= '';

    my @diffs = sdiff([ _split_text($old // '', $split) ], [ _split_text($new // '', $split) ]);

    return $self->_render_side_diff($filter, @diffs);
}

sub diff_html_side {
    my ($self, $old, $new, $filter) = @_;

    my $old_root = HTML::TreeBuilder->new_from_content('<body>'.($old // '').'</body>');
    my @old_tokens = map {
        _html_token($_)
    } $old_root->content_array_ref->[1]->content_list;

    my $new_root = HTML::TreeBuilder->new_from_content('<body>'.($new // '').'</body>');
    my @new_tokens = map {
        _html_token($_)
    } $new_root->content_array_ref->[1]->content_list;

    my @diffs = sdiff(\@old_tokens, \@new_tokens);

    return $self->_render_side_diff($filter, @diffs);
}

sub _html_token {
    my ($item) = @_;
    return blessed($item) ? $item->as_HTML : _split_text($item, '\s+');
}

sub _split_text {
    my ($text, $split) = @_;
    my $hex = md5_hex(encode('utf-8', $text));
    $text =~ s/($split)/$hex$1/g;
    return split($hex,$text);
}

sub _render_side_diff {
    my ($self, $filter, @diffs) = @_;

    my @stack;
    for my $diff (@diffs) {
        my ($change_type, $old, $new) = @$diff;

        next unless
            $change_type eq 'c' ||
            $change_type eq 'u' ||
            $change_type eq $filter;

        unless ($stack[-1] && $stack[-1]->{type} eq $change_type) {
            push @stack, { str => '', type => $change_type };
        }

        if ($change_type eq 'c') {
            $stack[-1]->{str} .=
                $filter eq '+'
                    ? "$new" : "$old";
        }
        else {
            $stack[-1]->{str} .= $change_type eq '+' ? $new : $old;
        }
    }

    return join(
        '',
        map {
            my $class =
                $_->{type} eq 'u' ? '' :
                $_->{type} eq 'c' ? $class_map{$filter} :
                                    $class_map{$_->{type}};

            my $text = $_->{str};
            $h->span({ class => $class }, $text)
        } @stack
    )
}

sub _link_artist_credit_name {
    my ($self, $acn, $name) = @_;
    my $comment;
    if ($acn->artist->comment) {
        $comment = ' (' . $acn->artist->comment . ')';
    }
    else {
        $comment = '';
    }

    if ($acn->artist->gid) {
        return $h->a({
            href => $self->uri_for_action('/artist/show', [ $acn->artist->gid ]),
            title => $acn->artist->sort_name . $comment
        }, $name || encode_entities($acn->name));
    }
    else {
        return $h->span({
            class => 'deleted tooltip',
            title => l('This entity has been removed, and cannot be displayed correctly.')
        }, $name || encode_entities($acn->name));
    }
}

sub _link_joined {
    my ($self, $acn) = @_;
    return $self->_link_artist_credit_name($acn) . (encode_entities($acn->join_phrase) || '');
}

sub diff_artist_credits {
    my ($self, $old, $new) = @_;

    my @diffs = sdiff(
        $old->names,
        $new->names,
        sub {
            my $name = shift;
            join(
                '',
                $name->artist->id || 'deleted',
                $name->name,
                $name->join_phrase || ''
            );
        }
    );

    my %sides = map { $_ => '' } qw( old new );
    for my $diff (@diffs) {
        my ($change_type, $old_name, $new_name) = @$diff;

        given ($change_type) {
            when ('u') {
                my $html = $self->_link_joined($old_name);
                $sides{old} .= $html;
                $sides{new} .= $html;
            };

            when ('c') {
                # Diff the credited names
                $sides{old} .= $self->_link_artist_credit_name(
                    $old_name,
                    $self->diff_side($old_name->name, $new_name->name, '-','\s+')
                );
                $sides{new} .= $self->_link_artist_credit_name(
                    $new_name,
                    $self->diff_side($old_name->name, $new_name->name, '+', '\s+')
                );

                # Diff the join phrases
                $sides{old} .= $self->diff_side($old_name->join_phrase, $new_name->join_phrase, '-', '\s+');
                $sides{new} .= $self->diff_side($old_name->join_phrase, $new_name->join_phrase, '+', '\s+');
            }

            when ('-') {
                $sides{old} .= $h->span(
                    { class => $class_map{'-'} },
                    $self->_link_joined($old_name)
                );
            }

            when ('+') {
                $sides{new} .= $h->span(
                    { class => $class_map{'+'} },
                    $self->_link_joined($new_name)
                );
            }
        }
    }

    return \%sides;
}

sub diff {
    my ($self, $old, $new) = @_;
    my $h = HTML::Tiny->new;

    my @spans;

    my @a = parse_paragraphs($old);
    my @b = parse_paragraphs($new);

    my %buffers = (
        MATCH     => '',
        DISCARD_A => '',
        DISCARD_B => ''
    );

    my %classes = (
        MATCH     => 'diff-match',
        DISCARD_A => 'diff-only-a',
        DISCARD_B => 'diff-only-b',
    );

    my $flush = sub {
        my $exclude = shift;

        while (my ($key, $class) = each %classes) {
            next if $exclude eq $key || !$buffers{$key};
            push @spans, $h->span({ class => $class }, $buffers{$key});
            $buffers{$key} = '';
        }
    };

    my @compact = traverse_sequences(
        \@a, \@b, {
            MATCH     => sub {
                $flush->('MATCH');
                $buffers{MATCH} .= $a[shift];
            },
            DISCARD_A => sub {
                $flush->('DISCARD_A');
                $buffers{DISCARD_A} .= $a[shift];
            },
            DISCARD_B => sub {
                $flush->('DISCARD_B');
                shift;
                $buffers{DISCARD_B} .= $b[shift];
            },
        }
    );

    $flush->('');

    return $h->div({ class => 'diff' }, \@spans);
}

sub parse_text
{
    my ($text) = @_;
    $text =~ s/\s+/ /g;
    $text =~ s/\A //g;
    $text =~ s/ \z//g;
    # The spaces between words are included as part of the word tokens to make
    # the "diff" output more intuitive; for example if you diff "a big red
    # ball" to "a small green ball", the obvious diff is s/big red/small
    # green/.  If spaces were their own tokens, the diff would be s/big/small/
    # and s/red/green/.
    return split /(?= )/, $text;
}

sub parse_paragraphs
{
    my $text = shift;

    $text =~ s/(\015\012|\012\015|\012|\015)\1+/\n\n/g;
    trim_in_place($text);

    my @paras = split /\n\n+/, $text;

    my @out;
    for my $p (@paras) {
#       push @out, $TOKEN_NEW_PARA if @out;
        push @out, parse_text($p);
    }

    return @out;
}

1;
