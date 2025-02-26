defmodule Path do
  @moduledoc """
  This module provides conveniences for manipulating or
  retrieving file system paths.

  The functions in this module may receive chardata as
  arguments and will always return a string encoded in UTF-8. Chardata
  is a string or a list of characters and strings, see `t:IO.chardata/0`.
  If a binary is given, in whatever encoding, its encoding will be kept.

  The majority of the functions in this module do not
  interact with the file system, except for a few functions
  that require it (like `wildcard/2` and `expand/1`).
  """

  @typedoc """
  A path.
  """
  @type t :: IO.chardata()

  @doc """
  Converts the given path to an absolute one.

  Unlike `expand/1`, no attempt is made to resolve `..`, `.`, or `~`.

  ## Examples

  ### Unix-like operating systems

      Path.absname("foo")
      #=> "/usr/local/foo"

      Path.absname("../x")
      #=> "/usr/local/../x"

  ### Windows

      Path.absname("foo")
      #=> "D:/usr/local/foo"

      Path.absname("../x")
      #=> "D:/usr/local/../x"

  """
  @spec absname(t) :: binary
  def absname(path) do
    absname(path, File.cwd!())
  end

  @doc """
  Builds a path from `relative_to` to `path`.

  If `path` is already an absolute path, `relative_to` is ignored. See also
  `relative_to/2`.

  Unlike `expand/2`, no attempt is made to
  resolve `..`, `.` or `~`.

  ## Examples

      iex> Path.absname("foo", "bar")
      "bar/foo"

      iex> Path.absname("../x", "bar")
      "bar/../x"

  """
  @spec absname(t, t) :: binary
  def absname(path, relative_to) do
    path = IO.chardata_to_string(path)

    case type(path) do
      :relative ->
        absname_join([relative_to, path])

      :absolute ->
        absname_join([path])

      :volumerelative ->
        relative_to = IO.chardata_to_string(relative_to)
        absname_vr(split(path), split(relative_to), relative_to)
    end
  end

  # Absolute path on current drive
  defp absname_vr(["/" | rest], [volume | _], _relative), do: absname_join([volume | rest])

  # Relative to current directory on current drive
  defp absname_vr([<<x, ?:>> | rest], [<<x, _::binary>> | _], relative),
    do: absname(absname_join(rest), relative)

  # Relative to current directory on another drive
  defp absname_vr([<<x, ?:>> | name], _, _relative) do
    cwd =
      case :file.get_cwd([x, ?:]) do
        {:ok, dir} -> IO.chardata_to_string(dir)
        {:error, _} -> <<x, ?:, ?/>>
      end

    absname(absname_join(name), cwd)
  end

  @slash [?/, ?\\]

  defp absname_join([]), do: ""
  defp absname_join(list), do: absname_join(list, major_os_type())

  defp absname_join([name1, name2 | rest], os_type) do
    joined = do_absname_join(IO.chardata_to_string(name1), relative(name2), [], os_type)
    absname_join([joined | rest], os_type)
  end

  defp absname_join([name], os_type) do
    do_absname_join(IO.chardata_to_string(name), <<>>, [], os_type)
  end

  defp do_absname_join(<<uc_letter, ?:, rest::binary>>, relativename, [], :win32)
       when uc_letter in ?A..?Z,
       do: do_absname_join(rest, relativename, [?:, uc_letter + ?a - ?A], :win32)

  defp do_absname_join(<<c1, c2, rest::binary>>, relativename, [], :win32)
       when c1 in @slash and c2 in @slash,
       do: do_absname_join(rest, relativename, ~c"//", :win32)

  defp do_absname_join(<<?\\, rest::binary>>, relativename, result, :win32),
    do: do_absname_join(<<?/, rest::binary>>, relativename, result, :win32)

  defp do_absname_join(<<?/, rest::binary>>, relativename, [?., ?/ | result], os_type),
    do: do_absname_join(rest, relativename, [?/ | result], os_type)

  defp do_absname_join(<<?/, rest::binary>>, relativename, [?/ | result], os_type),
    do: do_absname_join(rest, relativename, [?/ | result], os_type)

  defp do_absname_join(<<>>, <<>>, result, os_type),
    do: IO.iodata_to_binary(reverse_maybe_remove_dir_sep(result, os_type))

  defp do_absname_join(<<>>, relativename, [?: | rest], :win32),
    do: do_absname_join(relativename, <<>>, [?: | rest], :win32)

  defp do_absname_join(<<>>, relativename, [?/ | result], os_type),
    do: do_absname_join(relativename, <<>>, [?/ | result], os_type)

  defp do_absname_join(<<>>, relativename, result, os_type),
    do: do_absname_join(relativename, <<>>, [?/ | result], os_type)

  defp do_absname_join(<<char, rest::binary>>, relativename, result, os_type),
    do: do_absname_join(rest, relativename, [char | result], os_type)

  defp reverse_maybe_remove_dir_sep([?/, ?:, letter], :win32), do: [letter, ?:, ?/]
  defp reverse_maybe_remove_dir_sep([?/], _), do: [?/]
  defp reverse_maybe_remove_dir_sep([?/ | name], _), do: :lists.reverse(name)
  defp reverse_maybe_remove_dir_sep(name, _), do: :lists.reverse(name)

  @doc """
  Converts the path to an absolute one, expanding
  any `.` and `..` components and a leading `~`.

  ## Examples

      Path.expand("/foo/bar/../baz")
      #=> "/foo/baz"

  """
  @spec expand(t) :: binary
  def expand(path) do
    expand_dot(absname(expand_home(path), File.cwd!()))
  end

  @doc """
  Expands the path relative to the path given as the second argument
  expanding any `.` and `..` characters.

  If the path is already an absolute path, `relative_to` is ignored.

  Note that this function treats a `path` with a leading `~` as
  an absolute one.

  The second argument is first expanded to an absolute path.

  ## Examples

      # Assuming that the absolute path to baz is /quux/baz
      Path.expand("foo/bar/../bar", "baz")
      #=> "/quux/baz/foo/bar"

      Path.expand("foo/bar/../bar", "/baz")
      #=> "/baz/foo/bar"

      Path.expand("/foo/bar/../bar", "/baz")
      #=> "/foo/bar"

  """
  @spec expand(t, t) :: binary
  def expand(path, relative_to) do
    expand_dot(absname(absname(expand_home(path), expand_home(relative_to)), File.cwd!()))
  end

  @doc """
  Returns the path type.

  ## Examples

  ### Unix-like operating systems

      Path.type("/")                #=> :absolute
      Path.type("/usr/local/bin")   #=> :absolute
      Path.type("usr/local/bin")    #=> :relative
      Path.type("../usr/local/bin") #=> :relative
      Path.type("~/file")           #=> :relative

  ### Windows

      Path.type("D:/usr/local/bin") #=> :absolute
      Path.type("usr/local/bin")    #=> :relative
      Path.type("D:bar.ex")         #=> :volumerelative
      Path.type("/bar/foo.ex")      #=> :volumerelative

  """
  @spec type(t) :: :absolute | :relative | :volumerelative
  def type(name)
      when is_list(name)
      when is_binary(name) do
    pathtype(name, major_os_type()) |> elem(0)
  end

  @doc """
  Forces the path to be a relative path.

  ## Examples

  ### Unix-like operating systems

      Path.relative("/usr/local/bin")   #=> "usr/local/bin"
      Path.relative("usr/local/bin")    #=> "usr/local/bin"
      Path.relative("../usr/local/bin") #=> "../usr/local/bin"

  ### Windows

      Path.relative("D:/usr/local/bin") #=> "usr/local/bin"
      Path.relative("usr/local/bin")    #=> "usr/local/bin"
      Path.relative("D:bar.ex")         #=> "bar.ex"
      Path.relative("/bar/foo.ex")      #=> "bar/foo.ex"

  """
  # Note this function does not expand paths because the behaviour
  # is ambiguous. If we expand it before converting to relative, then
  # "/usr/../../foo" means "/foo". If we expand it after, it means "../foo".
  # We could expand only relative paths but it is best to say it never
  # expands and then provide a `Path.expand_relative` function (or an
  # option) if desired.
  @spec relative(t) :: binary
  def relative(name) do
    relative(name, major_os_type())
  end

  defp relative(name, os_type) do
    pathtype(name, os_type)
    |> elem(1)
    |> IO.chardata_to_string()
  end

  defp pathtype(name, os_type) do
    case os_type do
      :win32 -> win32_pathtype(name)
      _ -> unix_pathtype(name)
    end
  end

  defp unix_pathtype(path) when path in ["/", ~c"/"], do: {:absolute, "."}
  defp unix_pathtype(<<?/, relative::binary>>), do: {:absolute, relative}
  defp unix_pathtype([?/ | relative]), do: {:absolute, relative}
  defp unix_pathtype([list | rest]) when is_list(list), do: unix_pathtype(list ++ rest)
  defp unix_pathtype(relative), do: {:relative, relative}

  defp win32_pathtype([list | rest]) when is_list(list), do: win32_pathtype(list ++ rest)

  defp win32_pathtype([char, list | rest]) when is_list(list),
    do: win32_pathtype([char | list ++ rest])

  defp win32_pathtype(<<c1, c2, relative::binary>>) when c1 in @slash and c2 in @slash,
    do: {:absolute, relative}

  defp win32_pathtype(<<char, relative::binary>>) when char in @slash,
    do: {:volumerelative, relative}

  defp win32_pathtype(<<_letter, ?:, char, relative::binary>>) when char in @slash,
    do: {:absolute, relative}

  defp win32_pathtype(<<_letter, ?:, relative::binary>>), do: {:volumerelative, relative}

  defp win32_pathtype([c1, c2 | relative]) when c1 in @slash and c2 in @slash,
    do: {:absolute, relative}

  defp win32_pathtype([char | relative]) when char in @slash, do: {:volumerelative, relative}

  defp win32_pathtype([c1, c2, list | rest]) when is_list(list),
    do: win32_pathtype([c1, c2 | list ++ rest])

  defp win32_pathtype([_letter, ?:, char | relative]) when char in @slash,
    do: {:absolute, relative}

  defp win32_pathtype([_letter, ?: | relative]), do: {:volumerelative, relative}
  defp win32_pathtype(relative), do: {:relative, relative}

  @doc """
  Returns the direct relative path from `path` in relation to `cwd`.

  In other words, this function tries to strip the `cwd` prefix
  from `path`. For this reason, `cwd` must be an absolute path.

  If `path` is already a relative path, any `..` or `.` are
  expanded, but without computing its absolute path. If an absolute
  path is given and no relative paths are found, it returns the
  original path expanded.

  This function does not query the file system, so it assumes
  no symlinks between the paths. See `safe_relative_to/2` for
  a safer alternative.

  ## Examples

  With absolute paths:

      Path.relative_to("/usr/local/foo", "/usr/local")      #=> "foo"
      Path.relative_to("/usr/local/foo", "/")               #=> "usr/local/foo"
      Path.relative_to("/usr/local/foo", "/etc")            #=> "/usr/local/foo"
      Path.relative_to("/usr/local/foo", "/usr/local/foo")  #=> "."
      Path.relative_to("/usr/local/../foo", "/usr/foo")     #=> "."
      Path.relative_to("/usr/local/../foo/bar", "/usr/foo") #=> "bar"

  Relative paths have "." and ".." expanded but kept as relative:

      Path.relative_to(".", "/usr/local")          #=> "."
      Path.relative_to("foo", "/usr/local")        #=> "foo"
      Path.relative_to("foo/../bar", "/usr/local") #=> "bar"
      Path.relative_to("foo/..", "/usr/local")     #=> "."
      Path.relative_to("../foo", "/usr/local")     #=> "../foo"

  """
  @spec relative_to(t, t) :: binary
  def relative_to(path, cwd) do
    os_type = major_os_type()
    split_path = split(path)
    split_cwd = split(cwd)

    cond do
      # cwd must be an absolute path, if not, compute common path for backwards compatibility
      # TODO: Raise on Elixir v2.0
      not split_absolute?(split_cwd, os_type) ->
        IO.warn(
          "the second argument to Path.relative_to/2 must be an absolute path, got: #{inspect(cwd)}"
        )

        relative_to(split_path, split_cwd, split_path)

      # If source is a relative path, expand ./.. as much as possible and return it
      not split_absolute?(split_path, os_type) ->
        expand_relative(split_path, [], [])

      # Otherwise attempt to find a common path after expansion
      true ->
        split_path = expand_split(split_path)
        split_cwd = expand_split(split_cwd)
        relative_to(split_path, split_cwd, split_path)
    end
  end

  defp relative_to(path, path, _original), do: "."
  defp relative_to([h | t1], [h | t2], original), do: relative_to(t1, t2, original)
  defp relative_to([_ | _] = l1, [], _original), do: join(l1)
  defp relative_to(_, _, original), do: join(original)

  defp expand_relative([".." | t], [_ | acc], up), do: expand_relative(t, acc, up)
  defp expand_relative([".." | t], acc, up), do: expand_relative(t, acc, [".." | up])
  defp expand_relative(["." | t], acc, up), do: expand_relative(t, acc, up)
  defp expand_relative([h | t], acc, up), do: expand_relative(t, [h | acc], up)
  defp expand_relative([], [], []), do: "."
  defp expand_relative([], acc, up), do: join(up ++ :lists.reverse(acc))

  defp expand_split([head | tail]), do: expand_split(tail, [head])
  defp expand_split([".." | t], [_, last | acc]), do: expand_split(t, [last | acc])
  defp expand_split([".." | t], acc), do: expand_split(t, acc)
  defp expand_split(["." | t], acc), do: expand_split(t, acc)
  defp expand_split([h | t], acc), do: expand_split(t, [h | acc])
  defp expand_split([], acc), do: :lists.reverse(acc)

  defp split_absolute?(split, :win32), do: win32_split_absolute?(split)
  defp split_absolute?(split, _), do: match?(["/" | _], split)

  defp win32_split_absolute?(["//" | _]), do: true
  defp win32_split_absolute?([<<_, ":/">> | _]), do: true
  defp win32_split_absolute?(_), do: false

  @doc """
  Convenience to get the path relative to the current working
  directory.

  If, for some reason, the current working directory
  cannot be retrieved, this function returns the given `path`.
  """
  @spec relative_to_cwd(t) :: binary
  def relative_to_cwd(path) do
    case :file.get_cwd() do
      {:ok, base} -> relative_to(path, IO.chardata_to_string(base))
      _ -> path
    end
  end

  @doc """
  Returns the last component of the path or the path
  itself if it does not contain any directory separators.

  ## Examples

      iex> Path.basename("foo")
      "foo"

      iex> Path.basename("foo/bar")
      "bar"

      iex> Path.basename("lib/module/submodule.ex")
      "submodule.ex"

      iex> Path.basename("/")
      ""

  """
  @spec basename(t) :: binary
  def basename(path) do
    :filename.basename(IO.chardata_to_string(path))
  end

  @doc """
  Returns the last component of `path` with the `extension`
  stripped.

  This function should be used to remove a specific
  extension which may or may not be there.

  ## Examples

      iex> Path.basename("~/foo/bar.ex", ".ex")
      "bar"

      iex> Path.basename("~/foo/bar.exs", ".ex")
      "bar.exs"

      iex> Path.basename("~/foo/bar.old.ex", ".ex")
      "bar.old"

  """
  @spec basename(t, t) :: binary
  def basename(path, extension) do
    :filename.basename(IO.chardata_to_string(path), IO.chardata_to_string(extension))
  end

  @doc """
  Returns the directory component of `path`.

  ## Examples

      iex> Path.dirname("/foo/bar.ex")
      "/foo"

      iex> Path.dirname("/foo/bar/baz.ex")
      "/foo/bar"

      iex> Path.dirname("/foo/bar/")
      "/foo/bar"

      iex> Path.dirname("bar.ex")
      "."

  """
  @spec dirname(t) :: binary
  def dirname(path) do
    :filename.dirname(IO.chardata_to_string(path))
  end

  @doc """
  Returns the extension of the last component of `path`.

  For filenames starting with a dot and without an extension, it returns
  an empty string.

  See `basename/1` and `rootname/1` for related functions to extract
  information from paths.

  ## Examples

      iex> Path.extname("foo.erl")
      ".erl"

      iex> Path.extname("~/foo/bar")
      ""

      iex> Path.extname(".gitignore")
      ""

  """
  @spec extname(t) :: binary
  def extname(path) do
    :filename.extension(IO.chardata_to_string(path))
  end

  @doc """
  Returns the `path` with the `extension` stripped.

  ## Examples

      iex> Path.rootname("/foo/bar")
      "/foo/bar"

      iex> Path.rootname("/foo/bar.ex")
      "/foo/bar"

  """
  @spec rootname(t) :: binary
  def rootname(path) do
    :filename.rootname(IO.chardata_to_string(path))
  end

  @doc """
  Returns the `path` with the `extension` stripped.

  This function should be used to remove a specific extension which may
  or may not be there.

  ## Examples

      iex> Path.rootname("/foo/bar.erl", ".erl")
      "/foo/bar"

      iex> Path.rootname("/foo/bar.erl", ".ex")
      "/foo/bar.erl"

  """
  @spec rootname(t, t) :: binary
  def rootname(path, extension) do
    :filename.rootname(IO.chardata_to_string(path), IO.chardata_to_string(extension))
  end

  @doc """
  Joins a list of paths.

  This function should be used to convert a list of paths to a path.
  Note that any trailing slash is removed when joining.

  Raises an error if the given list of paths is empty.

  ## Examples

      iex> Path.join(["~", "foo"])
      "~/foo"

      iex> Path.join(["foo"])
      "foo"

      iex> Path.join(["/", "foo", "bar/"])
      "/foo/bar"

  """
  @spec join(nonempty_list(t)) :: binary
  def join([name1, name2 | rest]), do: join([join(name1, name2) | rest])
  def join([name]), do: IO.chardata_to_string(name)

  @doc """
  Joins two paths.

  The right path will always be expanded to its relative format
  and any trailing slash will be removed when joining.

  ## Examples

      iex> Path.join("foo", "bar")
      "foo/bar"

      iex> Path.join("/foo", "/bar/")
      "/foo/bar"

  The functions in this module support chardata, so giving a list will
  treat it as a single entity:

      iex> Path.join("foo", ["bar", "fiz"])
      "foo/barfiz"

      iex> Path.join(["foo", "bar"], "fiz")
      "foobar/fiz"

  Use `join/1` if you need to join a list of paths instead.
  """
  @spec join(t, t) :: binary
  def join(left, right) do
    left = IO.chardata_to_string(left)
    os_type = major_os_type()
    do_join(left, right, os_type) |> remove_dir_sep(os_type)
  end

  defp do_join(left, "/", os_type), do: remove_dir_sep(left, os_type)
  defp do_join("", right, os_type), do: relative(right, os_type)
  defp do_join("/", right, os_type), do: "/" <> relative(right, os_type)

  defp do_join(left, right, os_type),
    do: remove_dir_sep(left, os_type) <> "/" <> relative(right, os_type)

  defp remove_dir_sep("", _os_type), do: ""
  defp remove_dir_sep("/", _os_type), do: "/"

  defp remove_dir_sep(bin, os_type) do
    last = :binary.last(bin)

    if last == ?/ or (last == ?\\ and os_type == :win32) do
      binary_part(bin, 0, byte_size(bin) - 1)
    else
      bin
    end
  end

  @doc ~S"""
  Splits the path into a list at the path separator.

  If an empty string is given, returns an empty list.

  On Windows, path is split on both `"\"` and `"/"` separators
  and the driver letter, if there is one, is always returned
  in lowercase.

  ## Examples

      iex> Path.split("")
      []

      iex> Path.split("foo")
      ["foo"]

      iex> Path.split("/foo/bar")
      ["/", "foo", "bar"]

  """
  @spec split(t) :: [binary]
  def split(path) do
    :filename.split(IO.chardata_to_string(path))
  end

  defmodule Wildcard do
    @moduledoc false

    def read_link_info(file) do
      :file.read_link_info(file)
    end

    def read_file_info(file) do
      :file.read_file_info(file)
    end

    def list_dir(dir) do
      case :file.list_dir(dir) do
        {:ok, files} -> {:ok, for(file <- files, hd(file) != ?., do: file)}
        other -> other
      end
    end
  end

  @doc ~S"""
  Traverses paths according to the given `glob` expression and returns a
  list of matches.

  The wildcard looks like an ordinary path, except that the following
  "wildcard characters" are interpreted in a special way:

    * `?` - matches one character.

    * `*` - matches any number of characters up to the end of the filename, the
      next dot, or the next slash.

    * `**` - two adjacent `*`'s used as a single pattern will match all
      files and zero or more directories and subdirectories.

    * `[char1,char2,...]` - matches any of the characters listed; two
      characters separated by a hyphen will match a range of characters.
      Do not add spaces before and after the comma as it would then match
      paths containing the space character itself.

    * `{item1,item2,...}` - matches one of the alternatives.
      Do not add spaces before and after the comma as it would then match
      paths containing the space character itself.

  Other characters represent themselves. Only paths that have
  exactly the same character in the same position will match. Note
  that matching is case-sensitive: `"a"` will not match `"A"`.

  Directory separators must always be written as `/`, even on Windows.
  You may call `Path.expand/1` to normalize the path before invoking
  this function.

  A character preceded by \ loses its special meaning.
  Note that \ must be written as \\ in a string literal.
  For example, "\\?*" will match any filename starting with ?.

  By default, the patterns `*` and `?` do not match files starting
  with a dot `.`. See the `:match_dot` option in the "Options" section
  below.

  ## Options

    * `:match_dot` - (boolean) if `false`, the special wildcard characters `*` and `?`
      will not match files starting with a dot (`.`). If `true`, files starting with
      a `.` will not be treated specially. Defaults to `false`.

  ## Examples

  Imagine you have a directory called `projects` with three Elixir projects
  inside of it: `elixir`, `ex_doc`, and `plug`. You can find all `.beam` files
  inside the `ebin` directory of each project as follows:

      Path.wildcard("projects/*/ebin/**/*.beam")

  If you want to search for both `.beam` and `.app` files, you could do:

      Path.wildcard("projects/*/ebin/**/*.{beam,app}")

  """
  @spec wildcard(t, keyword) :: [binary]
  def wildcard(glob, opts \\ []) when is_list(opts) do
    mod = if Keyword.get(opts, :match_dot), do: :file, else: Path.Wildcard

    glob
    |> chardata_to_list!()
    |> :filelib.wildcard(mod)
    |> Enum.map(&IO.chardata_to_string/1)
  end

  defp chardata_to_list!(chardata) do
    case :unicode.characters_to_list(chardata) do
      result when is_list(result) ->
        if 0 in result do
          raise ArgumentError,
                "cannot execute Path.wildcard/2 for path with null byte, got: #{inspect(chardata)}"
        else
          result
        end

      {:error, encoded, rest} ->
        raise UnicodeConversionError, encoded: encoded, rest: rest, kind: :invalid

      {:incomplete, encoded, rest} ->
        raise UnicodeConversionError, encoded: encoded, rest: rest, kind: :incomplete
    end
  end

  defp expand_home(type) do
    case IO.chardata_to_string(type) do
      "~" <> rest -> resolve_home(rest)
      rest -> rest
    end
  end

  defp resolve_home(""), do: System.user_home!()

  defp resolve_home(rest) do
    case {rest, major_os_type()} do
      {"\\" <> _, :win32} -> System.user_home!() <> rest
      {"/" <> _, _} -> System.user_home!() <> rest
      _ -> "~" <> rest
    end
  end

  # expands dots in an absolute path represented as a string
  defp expand_dot(path) do
    [head | tail] = :binary.split(path, "/", [:global])
    IO.iodata_to_binary(expand_dot(tail, [head <> "/"]))
  end

  defp expand_dot([".." | t], [_, _ | acc]), do: expand_dot(t, acc)
  defp expand_dot([".." | t], acc), do: expand_dot(t, acc)
  defp expand_dot(["." | t], acc), do: expand_dot(t, acc)
  defp expand_dot([h | t], acc), do: expand_dot(t, ["/", h | acc])
  defp expand_dot([], ["/", head | acc]), do: :lists.reverse([head | acc])
  defp expand_dot([], acc), do: :lists.reverse(acc)

  defp major_os_type do
    :os.type() |> elem(0)
  end

  @doc """
  Returns a relative path that is protected from directory-traversal attacks.

  The given relative path is sanitized by eliminating `..` and `.` components.

  This function checks that, after expanding those components, the path is still "safe".
  Paths are considered unsafe if either of these is true:

    * The path is not relative, such as `"/foo/bar"`.

    * A `..` component would make it so that the path would travers up above
      the root of `relative_to`.

    * A symbolic link in the path points to something above the root of `cwd`.

  ## Examples

      iex> Path.safe_relative_to("deps/my_dep/app.beam", File.cwd!())
      {:ok, "deps/my_dep/app.beam"}

      iex> Path.safe_relative_to("deps/my_dep/./build/../app.beam", File.cwd!())
      {:ok, "deps/my_dep/app.beam"}

      iex> Path.safe_relative_to("my_dep/../..", File.cwd!())
      :error

      iex> Path.safe_relative_to("/usr/local", File.cwd!())
      :error

  """
  @doc since: "1.14.0"
  @spec safe_relative_to(t, t) :: {:ok, binary} | :error
  def safe_relative_to(path, cwd) do
    path = IO.chardata_to_string(path)

    case :filelib.safe_relative_path(path, cwd) do
      :unsafe -> :error
      relative_path -> {:ok, IO.chardata_to_string(relative_path)}
    end
  end

  @doc """
  Returns a path relative to the current working directory that is
  protected from directory-traversal attacks.

  Same as `safe_relative_to/2` with the current working directory as
  the second argument. If there is an issue retrieving the current working
  directory, this function raises an error.

  ## Examples

      iex> Path.safe_relative("foo")
      {:ok, "foo"}

      iex> Path.safe_relative("foo/../bar")
      {:ok, "bar"}

      iex> Path.safe_relative("foo/../..")
      :error

      iex> Path.safe_relative("/usr/local")
      :error

  """
  @doc since: "1.14.0"
  @spec safe_relative(t) :: {:ok, binary} | :error
  def safe_relative(path) do
    safe_relative_to(path, File.cwd!())
  end
end
