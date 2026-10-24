
const std = @import("std");
const git = @import("git.zig");
const HttpClient = @import("http_client.zig");

repositories: []Repository,
user: []const u8,
name: []const u8,
emails: [][]const u8,
repo_contributions: u32 = 0,
issue_contributions: u32 = 0,
commit_contributions: u32 = 0,
pr_contributions: u32 = 0,
review_contributions: u32 = 0,

const Statistics = @This();

const Repository = struct {
    name: []const u8,
    stars: u32,
    forks: u32,
    languages: ?[]Language,
    lines_changed: u32,
    views: u32,
    private: bool,
    clones: ?u32 = null,
    collaborators: ?u32 = null,
    contributors: ?u32 = null,
    total_lines_changed: u64 = 0,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.languages) |languages| {
            for (languages) |language| {
                language.deinit(allocator);
            }
            allocator.free(languages);
        }
    }

    pub fn getLinesChanged(
        self: *@This(),
        arena: *std.heap.ArenaAllocator,
        client: *HttpClient,
        user: []const u8,
    ) !std.http.Status {
        std.log.debug(
            "Trying to get lines of code changed for {s}...",
            .{self.name},
        );

        const response = try client.rest(
            try std.mem.concat(
                arena.allocator(),
                u8,
                &.{
                    "https://api.github.com/repos/",
                    self.name,
                    "/stats/contributors",
                },
            ),
        );
        defer client.allocator.free(response.body);

        if (response.status == .ok) {
            self.lines_changed = 0;
            self.total_lines_changed = 0;

            const authors = std.json.parseFromSliceLeaky(
                []struct {
                    author: ?struct {
                        login: []const u8,
                    } = null,
                    weeks: []struct {
                        a: u32,
                        d: u32,
                    },
                },
                arena.allocator(),
                response.body,
                .{ .ignore_unknown_fields = true },
            ) catch {
                std.log.info(
                    "Skipping lines changed by {s} in {s} due to invalid response.",
                    .{ user, self.name },
                );
                return response.status;
            };

            self.contributors = @intCast(authors.len);

            for (authors) |author| {
                for (author.weeks) |week| {
                    const changed: u64 =
                        @as(u64, week.a) + @as(u64, week.d);

                    self.total_lines_changed += changed;

                    if (author.author) |account| {
                        if (std.mem.eql(u8, account.login, user)) {
                            self.lines_changed += week.a;
                            self.lines_changed += week.d;
                        }
                    }
                }
            }

            std.log.info(
                "Got {d} line{s} changed by {s} in {s}",
                .{
                    self.lines_changed,
                    if (self.lines_changed != 1) "s" else "",
                    user,
                    self.name,
                },
            );
        }

        return response.status;
    }
};

const Language = struct {
    name: []const u8,
    size: u32,
    color: ?[]const u8 = null,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.color) |color| {
            allocator.free(color);
        }
    }
};

pub fn init(
    client: *HttpClient,
    allocator: std.mem.Allocator,
    io: std.Io,
    max_retries: ?usize,
) !Statistics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var self: Statistics = try getRepos(allocator, &arena, client);
    errdefer self.deinit(allocator);

    try self.getLinesChanged(&arena, io, client, max_retries);
    return self;
}

pub fn initFromJson(
    allocator: std.mem.Allocator,
    s: []const u8,
) !Statistics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Statistics,
        arena.allocator(),
        s,
        .{ .ignore_unknown_fields = true },
    );

    return try deepcopy(allocator, parsed);
}

pub fn deinit(self: Statistics, allocator: std.mem.Allocator) void {
    for (self.repositories) |repository| {
        repository.deinit(allocator);
    }

    allocator.free(self.repositories);
    allocator.free(self.user);
    allocator.free(self.name);

    for (self.emails) |email| {
        allocator.free(email);
    }

    allocator.free(self.emails);
}

fn getBasicInfo(
    client: *HttpClient,
    arena: *std.heap.ArenaAllocator,
) !struct {
    years: []u32,
    user: []const u8,
    name: ?[]const u8,
    emails: [][]const u8,
} {
    std.log.info("Getting contribution years...", .{});

    const response = try client.graphql(
        \\query {
        \\  viewer {
        \\    login
        \\    name
        \\    contributionsCollection {
        \\      contributionYears
        \\    }
        \\  }
        \\}
    , null);

    defer client.allocator.free(response.body);

    if (response.status != .ok) {
        std.log.err(
            "Failed to get contribution years ({?s})",
            .{response.status.phrase()},
        );
        return error.RequestFailed;
    }

    const parsed = (try std.json.parseFromSliceLeaky(
        struct {
            data: struct {
                viewer: struct {
                    login: []const u8,
                    name: ?[]const u8,
                    contributionsCollection: struct {
                        contributionYears: []u32,
                    },
                },
            },
        },
        arena.allocator(),
        response.body,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    )).data.viewer;

    std.log.info("Getting contributor emails...", .{});

    const email_response =
        try client.rest("https://api.github.com/user/emails");

    defer client.allocator.free(email_response.body);

    var emails: [][]const u8 = &.{};

    if (email_response.status == .ok) {
        const parsed_emails = try std.json.parseFromSliceLeaky(
            []struct {
                email: []const u8,
            },
            arena.allocator(),
            email_response.body,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        );

        if (parsed_emails.len > 0) {
            emails = try arena.allocator().alloc(
                []const u8,
                parsed_emails.len,
            );

            for (parsed_emails, emails) |src, *dest| {
                dest.* = src.email;
            }
        }
    } else {
        std.log.err(
            "Failed to get user emails. Token may be missing `user:email` permission.",
            .{},
        );
    }

    if (emails.len == 0) {
        emails = try arena.allocator().alloc([]const u8, 1);

        emails[0] = try std.fmt.allocPrint(
            arena.allocator(),
            "{s}@users.noreply.github.com",
            .{parsed.login},
        );
    }

    return .{
        .years = parsed.contributionsCollection.contributionYears,
        .user = parsed.login,
        .name = parsed.name,
        .emails = emails,
    };
}

fn getReposByYear(
    context: struct {
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        client: *HttpClient,
        user: []const u8,
        result: *Statistics,
        seen: *std.StringHashMap(bool),
        repositories: *std.ArrayList(Repository),
    },
    year: usize,
    start_month: usize,
    months: usize,
) !void {
    std.log.info(
        "Getting {d} month{s} of data starting from {d}/{d}...",
        .{
            months,
            if (months != 1) "s" else "",
            start_month + 1,
            year,
        },
    );

    const response = try context.client.graphql(
        \\query ($from: DateTime, $to: DateTime) {
        \\  viewer {
        \\    contributionsCollection(from: $from, to: $to) {
        \\      totalRepositoryContributions
        \\      totalIssueContributions
        \\      totalCommitContributions
        \\      totalPullRequestContributions
        \\      totalPullRequestReviewContributions
        \\      commitContributionsByRepository(maxRepositories: 100) {
        \\        repository {
        \\          nameWithOwner
        \\          stargazerCount
        \\          forkCount
        \\          isPrivate
        \\          languages(
        \\            first: 100,
        \\            orderBy: { direction: DESC, field: SIZE }
        \\          ) {
        \\            edges {
        \\              size
        \\              node {
        \\                name
        \\                color
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{
            .from = try std.fmt.allocPrint(
                context.arena.allocator(),
                "{d}-{d:02}-01T00:00:00Z",
                .{ year, start_month + 1 },
            ),
            .to = try std.fmt.allocPrint(
                context.arena.allocator(),
                "{d}-{d:02}-01T00:00:00Z",
                .{
                    year + (start_month + months) / 12,
                    (start_month + months) % 12 + 1,
                },
            ),
        },
    );

    defer context.client.allocator.free(response.body);

    if (response.status != .ok) {
        std.log.err(
            "Failed to get data from {d} ({?s})",
            .{ year, response.status.phrase() },
        );
        return error.RequestFailed;
    }

    const stats = (try std.json.parseFromSliceLeaky(
        struct {
            data: struct {
                viewer: struct {
                    contributionsCollection: struct {
                        totalRepositoryContributions: u32,
                        totalIssueContributions: u32,
                        totalCommitContributions: u32,
                        totalPullRequestContributions: u32,
                        totalPullRequestReviewContributions: u32,
                        commitContributionsByRepository: []struct {
                            repository: struct {
                                nameWithOwner: []const u8,
                                stargazerCount: u32,
                                forkCount: u32,
                                isPrivate: bool,
                                languages: ?struct {
                                    edges: ?[]struct {
                                        size: u32,
                                        node: struct {
                                            name: []const u8,
                                            color: ?[]const u8,
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        context.arena.allocator(),
        response.body,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        },
    )).data.viewer.contributionsCollection;

    std.log.info(
        "Parsed {d} total repositories from {d}",
        .{
            stats.commitContributionsByRepository.len,
            year,
        },
    );

    const limit = 100;

    if (stats.commitContributionsByRepository.len >= limit) {
        for (&[_]usize{ 2, 3 }) |factor| {
            if (months % factor == 0) {
                for (0..factor) |i| {
                    try getReposByYear(
                        context,
                        year,
                        start_month + (months / factor) * i,
                        months / factor,
                    );
                }
                return;
            }
        } else {
            std.log.warn(
                "More than {d} repos returned for {d}/{d}. Some data may be omitted.",
                .{
                    limit,
                    start_month + 1,
                    year,
                },
            );
        }
    }

    context.result.repo_contributions +=
        stats.totalRepositoryContributions;

    context.result.issue_contributions +=
        stats.totalIssueContributions;

    context.result.commit_contributions +=
        stats.totalCommitContributions;

    context.result.pr_contributions +=
        stats.totalPullRequestContributions;

    context.result.review_contributions +=
        stats.totalPullRequestReviewContributions;

    for (stats.commitContributionsByRepository) |x| {
        const raw_repo = x.repository;

        if (context.seen.get(raw_repo.nameWithOwner) orelse false) {
            std.log.debug(
                "Skipping {s} (seen)",
                .{raw_repo.nameWithOwner},
            );
            continue;
        }

        var repository = Repository{
            .name = try context.allocator.dupe(
                u8,
                raw_repo.nameWithOwner,
            ),
            .stars = raw_repo.stargazerCount,
            .forks = raw_repo.forkCount,
            .private = raw_repo.isPrivate,
            .languages = null,
            .views = 0,
            .lines_changed = 0,
        };

        errdefer repository.deinit(context.allocator);

        if (raw_repo.languages) |repo_languages| {
            if (repo_languages.edges) |raw_languages| {
                repository.languages = try context.allocator.alloc(
                    Language,
                    raw_languages.len,
                );

                errdefer {
                    context.allocator.free(repository.languages.?);
                    repository.languages = null;
                }

                for (
                    raw_languages,
                    repository.languages.?,
                    0..,
                ) |raw, *language, i| {
                    errdefer {
                        for (0..i, repository.languages.?) |_, l| {
                            context.allocator.free(l.name);

                            if (l.color) |color| {
                                context.allocator.free(color);
                            }
                        }
                    }

                    language.* = .{
                        .name = try context.allocator.dupe(
                            u8,
                            raw.node.name,
                        ),
                        .size = raw.size,
                    };

                    errdefer context.allocator.free(language.name);

                    if (raw.node.color) |color| {
                        language.color =
                            try context.allocator.dupe(u8, color);
                    }

                    errdefer if (language.color) |color| {
                        context.allocator.free(color);
                    };
                }
            }
        }

        std.log.info(
            "Getting views for {s}...",
            .{raw_repo.nameWithOwner},
        );

        const views_response = try context.client.rest(
            try std.fmt.allocPrint(
                context.arena.allocator(),
                "https://api.github.com/repos/{s}/traffic/views",
                .{raw_repo.nameWithOwner},
            ),
        );

        defer context.client.allocator.free(views_response.body);

        if (views_response.status == .ok) {
            const views_data = std.json.parseFromSliceLeaky(
                struct {
                    count: u32,
                },
                context.arena.allocator(),
                views_response.body,
                .{ .ignore_unknown_fields = true },
            ) catch null;

            if (views_data) |data| {
                repository.views = data.count;
            }
        } else {
            std.log.info(
                "Failed to get views for {s} ({?s})",
                .{
                    raw_repo.nameWithOwner,
                    views_response.status.phrase(),
                },
            );
        }

        std.log.info(
            "Getting clones for {s}...",
            .{raw_repo.nameWithOwner},
        );

        const clones_response = try context.client.rest(
            try std.fmt.allocPrint(
                context.arena.allocator(),
                "https://api.github.com/repos/{s}/traffic/clones",
                .{raw_repo.nameWithOwner},
            ),
        );

        defer context.client.allocator.free(clones_response.body);

        if (clones_response.status == .ok) {
            const clones_data = std.json.parseFromSliceLeaky(
                struct {
                    count: u32,
                },
                context.arena.allocator(),
                clones_response.body,
                .{ .ignore_unknown_fields = true },
            ) catch null;

            if (clones_data) |data| {
                repository.clones = data.count;
            }
        } else {
            std.log.info(
                "Failed to get clones for {s} ({?s})",
                .{
                    raw_repo.nameWithOwner,
                    clones_response.status.phrase(),
                },
            );
        }

        std.log.info(
            "Getting collaborators for {s}...",
            .{raw_repo.nameWithOwner},
        );

        const collaborators_response = try context.client.rest(
            try std.fmt.allocPrint(
                context.arena.allocator(),
                "https://api.github.com/repos/{s}/collaborators?per_page=100",
                .{raw_repo.nameWithOwner},
            ),
        );

        defer context.client.allocator.free(collaborators_response.body);

        if (collaborators_response.status == .ok) {
            const collaborators_data = std.json.parseFromSliceLeaky(
                []std.json.Value,
                context.arena.allocator(),
                collaborators_response.body,
                .{ .ignore_unknown_fields = true },
            ) catch null;

            if (collaborators_data) |data| {
                repository.collaborators = @intCast(data.len);
            }
        } else {
            std.log.info(
                "Failed to get collaborators for {s} ({?s})",
                .{
                    raw_repo.nameWithOwner,
                    collaborators_response.status.phrase(),
                },
            );
        }

        _ = try repository.getLinesChanged(
            context.arena,
            context.client,
            context.user,
        );

        try context.seen.put(
            raw_repo.nameWithOwner,
            true,
        );

        try context.repositories.append(
            context.allocator,
            repository,
        );
    }
}

fn getRepos(
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    client: *HttpClient,
) !Statistics {
    var result: Statistics = .{
        .user = undefined,
        .name = undefined,
        .emails = undefined,
        .repositories = undefined,
    };

    var repositories: std.ArrayList(Repository) =
        try .initCapacity(allocator, 32);

    errdefer {
        for (repositories.items) |repo| {
            repo.deinit(allocator);
        }
        repositories.deinit(allocator);
    }

    var seen: std.StringHashMap(bool) =
        .init(arena.allocator());

    defer seen.deinit();

    const info = try getBasicInfo(client, arena);

    if (info.name) |n| {
        std.log.info(
            "Getting data for {s} ({s})...",
            .{ n, info.user },
        );
    } else {
        std.log.info(
            "Getting data for user {s}...",
            .{info.user},
        );
    }

    result.user = try allocator.dupe(
        u8,
        info.user,
    );

    errdefer allocator.free(result.user);

    result.name = try allocator.dupe(
        u8,
        info.name orelse info.user,
    );

    errdefer allocator.free(result.name);

    result.emails = try allocator.alloc(
        []const u8,
        info.emails.len,
    );

    errdefer allocator.free(result.emails);

    for (result.emails, info.emails, 0..) |*dest, src, i| {
        errdefer {
            for (result.emails[0..i]) |email| {
                allocator.free(email);
            }
        }

        dest.* = try allocator.dupe(u8, src);
    }

    errdefer {
        for (result.emails) |email| {
            allocator.free(email);
        }
    }

    for (info.years) |year| {
        try getReposByYear(
            .{
                .allocator = allocator,
                .arena = arena,
                .client = client,
                .user = info.user,
                .result = &result,
                .seen = &seen,
                .repositories = &repositories,
            },
            year,
            0,
            12,
        );
    }

    result.repositories =
        try repositories.toOwnedSlice(allocator);

    errdefer {
        for (result.repositories) |repository| {
            repository.deinit(allocator);
        }
        allocator.free(result.repositories);
    }

    std.sort.pdq(
        Repository,
        result.repositories,
        {},
        struct {
            pub fn lessThanFn(
                _: void,
                lhs: Repository,
                rhs: Repository,
            ) bool {
                if (rhs.views == lhs.views) {
                    return rhs.stars + rhs.forks <
                        lhs.stars + lhs.forks;
                }

                return rhs.views < lhs.views;
            }
        }.lessThanFn,
    );

    return result;
}

fn getLinesChanged(
    self: *Statistics,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    client: *HttpClient,
    max_retries: ?usize,
) !void {
    const allocator = arena.allocator();

    const T = struct {
        repo: *Repository,
        delay: i64,
        timestamp: i64,
        retries: usize,
    };

    var q: std.PriorityQueue(
        T,
        void,
        struct {
            pub fn compareFn(
                _: void,
                lhs: T,
                rhs: T,
            ) std.math.Order {
                return std.math.order(
                    lhs.timestamp,
                    rhs.timestamp,
                );
            }
        }.compareFn,
    ) = .empty;

    defer q.deinit(allocator);

    for (self.repositories) |*repo| {
        if (repo.lines_changed > 0) {
            continue;
        }

        try q.push(
            allocator,
            .{
                .repo = repo,
                .delay = 0,
                .timestamp =
                    std.Io.Clock.real.now(io).toSeconds(),
                .retries = 0,
            },
        );
    }

    while (q.pop()) |_item| {
        var item = _item;

        const now =
            std.Io.Clock.real.now(io).toSeconds();

        if (item.timestamp > now) {
            const delay = item.timestamp - now;

            std.log.debug(
                "Sleeping for {d}s. Waiting for {d} repo{s}.",
                .{
                    delay,
                    q.count() + 1,
                    if (q.count() + 1 != 1) "s" else "",
                },
            );

            try io.sleep(
                .fromSeconds(delay),
                .real,
            );
        }

        switch (try item.repo.getLinesChanged(
            arena,
            client,
            self.user,
        )) {
            .ok => {},

            .accepted,
            .forbidden,
            .too_many_requests,
            => {
                item.timestamp =
                    std.Io.Clock.real.now(io).toSeconds() +
                    item.delay;

                const random: std.Random.IoSource =
                    .{ .io = io };

                item.delay =
                    random.interface().intRangeAtMost(
                        i64,
                        0,
                        4,
                    );

                item.retries += 1;

                if (max_retries) |max| {
                    if (item.retries <= max) {
                        try q.push(
                            allocator,
                            item,
                        );
                    } else {
                        std.log.info(
                            "Cloning {s} to get lines changed...",
                            .{item.repo.name},
                        );

                        item.repo.lines_changed =
                            git.getLinesChanged(
                                arena.allocator(),
                                io,
                                self.user,
                                client.token,
                                item.repo.name,
                                self.emails,
                            ) catch |e| switch (e) {
                                error.GitNotInstalled => 0,
                                else => return e,
                            };

                        std.log.info(
                            "Got {d} line{s} changed by {s} in {s}",
                            .{
                                item.repo.lines_changed,
                                if (item.repo.lines_changed != 1)
                                    "s"
                                else
                                    "",
                                self.user,
                                item.repo.name,
                            },
                        );
                    }
                } else {
                    try q.push(
                        allocator,
                        item,
                    );
                }
            },

            else => |status| {
                std.log.info(
                    "Failed to get contribution data for {s} ({?s})",
                    .{
                        item.repo.name,
                        status.phrase(),
                    },
                );

                std.log.err(
                    "Request failed with response {?s}",
                    .{status.phrase()},
                );

                return error.RequestFailed;
            },
        }
    }
}

fn deepcopy(
    a: std.mem.Allocator,
    o: anytype,
) !@TypeOf(o) {
    return switch (@typeInfo(@TypeOf(o))) {
        .pointer => |p| switch (p.size) {
            .slice => v: {
                const result = try a.dupe(p.child, o);
                errdefer a.free(result);

                for (o, result) |src, *dest| {
                    dest.* = try deepcopy(a, src);
                }

                break :v result;
            },
            else => comptime unreachable,
        },

        .@"struct" => |s| v: {
            var result = o;

            inline for (s.fields) |field| {
                @field(result, field.name) =
                    try deepcopy(
                        a,
                        @field(o, field.name),
                    );
            }

            break :v result;
        },

        .optional => if (o) |v|
            try deepcopy(a, v)
        else
            null,

        else => o,
    };
}
