CLI commands supported by the Music & Artist information plugin
======

The Music & Artist Information plugin offers a few CLI commands to access some of its functionality.
They can be used like any other LMS CLI command.

*Please note*: all parameters need to be URI escaped. Eg. `c:/path/to/folder` would need to be sent as
`c%3A%2Fpath%2Fto%2Ffolder`. In the following reference I'm going to use the non-escaped versions for
improved human readability.

Textual content returned using these queries would be text only, stripped from any formatting of whatever
is found on the internet. No images, no formatting, nothing.

Reference
----

```
musicartistinfo albumreview [artist:abba album:gold | album_id:123] [lang:german]
```

Get an album's review. Use the `album_id` for local tracks. Or try your luck submitting the album title
and artist name. They would then be used to do a text match with the sources.

You can override the default language using an additional parameter. This would be useful if you were
listening to non-english music while your LMS was configured to use English as it's UI language.

```
musicartistinfo albumcovers [artist:abba album:gold | album_id:123 | mbid:abc]
```

Return a list of URLs for possible album covers for a given album. See previous `albumreview` command
for the parameters.

```
musicartistinfo lyrics [artist:abba title:waterloo | track_id:123 | url:]
```
Return lyrics for the given song. Again, `track_id` or `url` would directly point to a local track. For
tracks streamed from a service, use `artist` and `title` instead.

```
musicartistinfo artistphoto [artist:abba | artist_id:123]
```

Get a single URL with a possible artist portrait. Submit with either artist name or `artist_id` for
artists in your local music collection.

```
musicartistinfo artistphotos [artist:abba | artist_id:123]
```

Get a list of URLs with artist portraits. Submit with either artist name or `artist_id` for artists in
your local music collection.

```
musicartistinfo biography [artist:abba | artist_id:123]
```

Get the biography of the given artist.

```
musicartistinfo localfiles folder:/path/to/folder
```

Get URLs to text files available from the given folder. This is mostly useful if you store biographies
(`(artist|bio|biogra.*).*`) or reviews (`(album|review|albumreview).*`) in your music folders. Only
`*.pdf`, `*.txt`, `*.html`, `*.md`, and `*.nfo` files would be returned. The returned URLs would allow
you to show those files in a web browser.
