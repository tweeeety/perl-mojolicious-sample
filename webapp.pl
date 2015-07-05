use Mojolicious::Lite;

get '/' => sub {
  my $self = shift;

  $self->render(text => 'Hello World');
};

get 'book' => sub {
  my $self = shift;

  use DBIx::Connector;
  use utf8;

  # 接続の作成
  my $dsn = 'dbi:SQLite:dbname=test.db';
  my $conn = DBIx::Connector->new($dsn, undef, undef, {
      RaiseError => 1,
      PrintError => 0,
      AutoCommit => 1
  });

  # データベースハンドルの取得
  my $dbh  = $conn->dbh;

  # ステートメントハンドルの準備
  my $sth = $dbh->prepare('select * from book where title like ?');

  # SQLの実行
  my @params = ('%Perl%');
  $sth->execute(@params);

  # レコードの取得
  my $texts = '';
  my @texts;
  while (my $row =  $sth->fetchrow_hashref) {
    my $id = $row->{id};
    my $title = $row->{title};

    my $text = "id: $id, title: $title";

    use Encode 'decode';
    $text = decode('UTF-8', $text);

    $texts .= $text . " <br />";

    push @texts, $text;
  }

  # response
  $self->render(text => $texts);
};

app->start;
