-- Centralized filter definitions for guild recruitment and crafting-sale suppression.
ThunderfuryAutoIgnoreFilters = {
    recruitmentKeywords = {
        "recruit", "recruiting", "guild", "raid team", "core", "roster",
        "apply", "applications", "discord", "progression", "looking to fill",
        "fill spots", "raid group", "raid groups", "join our guild",
        "our guild", "casual guild", "social guild", "raiding guild",
        "new guild", "guild recruiting", "raid nights", "server time", "pm me",
        "whisper me"
    },

    recruitmentStrongPhrases = {
        "is recruiting", "guild looking to fill", "raid team", "raid days",
        "kara", "gruul", "mag", "dm for more info", "pst for more info",
        "calls for raid", "looking for", "tonight @", "tonight at"
    },

    recruitmentExcludeKeywords = {
        "wts", "wtb", "boost", "gdkp", "summon", "selling", "buying", "lfm",
        "lfg", "looking for more", "need 1", "need one", "one more",
        "pst for inv", "pst for invite", "whisper for invite", "inv for",
        "invite for", "sr run", "ms/os", "badge run", "heroic run",
        "normal run", "attunement run"
    },

    craftingSaleKeywords = {
        "wts", "selling", "can craft", "crafting", "craft", "lf customers",
        "taking orders", "commissions", "commission", "your mats", "my mats",
        "tips", "tip", "fee", "pst", "whisper", "tailoring:", "enchanting:",
        "blacksmithing:", "leatherworking:", "alchemy:", "jewelcrafting:",
        "engineering:", "inscription:", "[enchant "
    },

    craftingContextKeywords = {
        "tailoring", "enchanting", "blacksmithing", "leatherworking", "alchemy",
        "jewelcrafting", "engineering", "inscription", "primal nether",
        "nether vortex", "pattern", "recipe", "materials", "mats"
    }
}
