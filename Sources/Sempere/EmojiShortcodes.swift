import Foundation

/// A compact, built-in table of emoji shortcodes for `:name` completion in
/// naming fields (note titles, notebooks, tags). No network and no system
/// lookup: names are Unicode CLDR short names written in lowercase with `_`
/// for spaces (`grinning_face_with_smiling_eyes`), plus the short aliases
/// people type in Slack and GitHub (`smile`, `+1`, `heart`).
public enum EmojiShortcodes {
    /// One emoji and its names, the first being the one shown.
    public struct Entry: Hashable, Sendable {
        /// The emoji itself.
        public var emoji: String
        /// Its shortcodes without colons, the preferred one first.
        public var names: [String]

        public init(emoji: String, names: [String]) {
            self.emoji = emoji; self.names = names
        }
    }

    /// Every entry, in table order (roughly by popularity within groups).
    public static let entries: [Entry] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2, let emoji = parts.first else { return nil }
        return Entry(emoji: emoji, names: Array(parts.dropFirst()))
    }

    /// The emoji named exactly `name` (case-insensitive), or nil.
    public static func emoji(named name: String) -> String? {
        byName[name.lowercased()]
    }

    private static let byName: [String: String] = {
        var map: [String: String] = [:]
        for e in entries {
            for n in e.names where map[n] == nil { map[n] = e.emoji }
        }
        return map
    }()

    // Each line: the emoji, then its names. Aliases first where they are what people type.
    private static let table = """
😀 grinning grinning_face
😃 smiley grinning_face_with_big_eyes
😄 smile grinning_face_with_smiling_eyes
😁 grin beaming_face_with_smiling_eyes
😆 laughing satisfied grinning_squinting_face
😅 sweat_smile grinning_face_with_sweat
🤣 rofl rolling_on_the_floor_laughing
😂 joy face_with_tears_of_joy
🙂 slightly_smiling_face
🙃 upside_down_face
🫠 melting_face
😉 wink winking_face
😊 blush smiling_face_with_smiling_eyes
😇 innocent smiling_face_with_halo
🥰 smiling_face_with_hearts
😍 heart_eyes smiling_face_with_heart_eyes
🤩 star_struck
😘 kissing_heart face_blowing_a_kiss
😗 kissing kissing_face
☺️ relaxed smiling_face
😚 kissing_closed_eyes kissing_face_with_closed_eyes
😙 kissing_smiling_eyes kissing_face_with_smiling_eyes
🥲 smiling_face_with_tear
😋 yum face_savoring_food
😛 stuck_out_tongue face_with_tongue
😜 stuck_out_tongue_winking_eye winking_face_with_tongue
🤪 zany_face
😝 stuck_out_tongue_closed_eyes squinting_face_with_tongue
🤑 money_mouth_face
🤗 hugs smiling_face_with_open_hands hugging_face
🤭 hand_over_mouth face_with_hand_over_mouth
🫢 face_with_open_eyes_and_hand_over_mouth
🫣 face_with_peeking_eye
🤫 shushing_face
🤔 thinking thinking_face
🫡 saluting_face
🤐 zipper_mouth_face
🤨 raised_eyebrow face_with_raised_eyebrow
😐 neutral_face
😑 expressionless expressionless_face
😶 no_mouth face_without_mouth
🫥 dotted_line_face
😏 smirk smirking_face
😒 unamused unamused_face
🙄 roll_eyes face_with_rolling_eyes
😬 grimacing grimacing_face
🤥 lying_face
😌 relieved relieved_face
😔 pensive pensive_face
😪 sleepy sleepy_face
🤤 drooling_face
😴 sleeping sleeping_face
😷 mask face_with_medical_mask
🤒 face_with_thermometer
🤕 face_with_head_bandage
🤢 nauseated_face
🤮 vomiting_face face_vomiting
🤧 sneezing_face
🥵 hot_face
🥶 cold_face
🥴 woozy_face
😵 dizzy_face face_with_crossed_out_eyes
🤯 exploding_head
🤠 cowboy_hat_face
🥳 partying_face
🥸 disguised_face
😎 sunglasses smiling_face_with_sunglasses
🤓 nerd_face
🧐 monocle_face face_with_monocle
😕 confused confused_face
🫤 face_with_diagonal_mouth
😟 worried worried_face
🙁 slightly_frowning_face
☹️ frowning_face
😮 open_mouth face_with_open_mouth
😯 hushed hushed_face
😲 astonished astonished_face
😳 flushed flushed_face
🥺 pleading_face
🥹 face_holding_back_tears
😦 frowning frowning_face_with_open_mouth
😧 anguished anguished_face
😨 fearful fearful_face
😰 cold_sweat anxious_face_with_sweat
😥 disappointed_relieved sad_but_relieved_face
😢 cry crying_face
😭 sob loudly_crying_face
😱 scream face_screaming_in_fear
😖 confounded confounded_face
😣 persevere persevering_face
😞 disappointed disappointed_face
😓 sweat downcast_face_with_sweat
😩 weary weary_face
😫 tired_face
🥱 yawning_face
😤 triumph face_with_steam_from_nose
😡 rage pouting_face enraged_face
😠 angry angry_face
🤬 cursing_face face_with_symbols_on_mouth
😈 smiling_imp smiling_face_with_horns
👿 imp angry_face_with_horns
💀 skull
☠️ skull_and_crossbones
💩 poop hankey pile_of_poo
🤡 clown_face
👹 ogre
👺 goblin
👻 ghost
👽 alien
👾 space_invader alien_monster
🤖 robot
😺 smiley_cat grinning_cat
😸 smile_cat grinning_cat_with_smiling_eyes
😹 joy_cat cat_with_tears_of_joy
😻 heart_eyes_cat smiling_cat_with_heart_eyes
🙈 see_no_evil see_no_evil_monkey
🙉 hear_no_evil hear_no_evil_monkey
🙊 speak_no_evil speak_no_evil_monkey
💌 love_letter
💘 cupid heart_with_arrow
💝 gift_heart heart_with_ribbon
💖 sparkling_heart
💗 heartpulse growing_heart
💓 heartbeat beating_heart
💞 revolving_hearts
💕 two_hearts
💔 broken_heart
❤️ heart red_heart
🩷 pink_heart
🧡 orange_heart
💛 yellow_heart
💚 green_heart
💙 blue_heart
🩵 light_blue_heart
💜 purple_heart
🤎 brown_heart
🖤 black_heart
🩶 grey_heart
🤍 white_heart
💯 100 hundred_points
💢 anger anger_symbol
💥 boom collision
💫 dizzy
💦 sweat_drops sweat_droplets
💨 dash dashing_away
💬 speech_balloon
💭 thought_balloon
💤 zzz
👋 wave waving_hand
🤚 raised_back_of_hand
✋ hand raised_hand
🖖 vulcan_salute
👌 ok_hand
🤌 pinched_fingers
🤏 pinching_hand
✌️ v victory_hand
🤞 crossed_fingers
🫰 hand_with_index_finger_and_thumb_crossed
🤟 love_you_gesture
🤘 metal sign_of_the_horns
🤙 call_me_hand
👈 point_left backhand_index_pointing_left
👉 point_right backhand_index_pointing_right
👆 point_up_2 backhand_index_pointing_up
👇 point_down backhand_index_pointing_down
☝️ point_up index_pointing_up
👍 +1 thumbsup thumbs_up
👎 -1 thumbsdown thumbs_down
✊ fist raised_fist
👊 punch oncoming_fist
👏 clap clapping_hands
🙌 raised_hands
🫶 heart_hands
👐 open_hands
🤲 palms_up_together
🤝 handshake
🙏 pray folded_hands
✍️ writing_hand
💅 nail_care nail_polish
💪 muscle flexed_biceps
🧠 brain
👀 eyes
👁️ eye
👶 baby
🧒 child
👦 boy
👧 girl
🧑 adult person
👨 man
👩 woman
🧓 older_adult
👴 older_man
👵 older_woman
👨‍🎓 man_student
👩‍🎓 woman_student
🧑‍🎓 student
🧑‍🏫 teacher
🧑‍💻 technologist
🧑‍🔬 scientist
🧑‍⚕️ health_worker
🧑‍🍳 cook
🧑‍🎨 artist
🧑‍🚀 astronaut
🙋 raising_hand person_raising_hand
🤷 shrug person_shrugging
🤦 facepalm person_facepalming
🙇 bow person_bowing
🏃 runner running person_running
🚶 walking person_walking
💃 dancer woman_dancing
🧘 person_in_lotus_position yoga
👪 family
🐶 dog dog_face
🐱 cat cat_face
🐭 mouse mouse_face
🐹 hamster
🐰 rabbit rabbit_face
🦊 fox fox_face
🐻 bear
🐼 panda panda_face
🐨 koala
🐯 tiger tiger_face
🦁 lion
🐮 cow cow_face
🐷 pig pig_face
🐸 frog
🐵 monkey_face
🐒 monkey
🐔 chicken
🐧 penguin
🐦 bird
🐤 baby_chick
🦆 duck
🦅 eagle
🦉 owl
🦇 bat
🐺 wolf
🐗 boar
🐴 horse horse_face
🦄 unicorn
🐝 bee honeybee
🐛 bug
🦋 butterfly
🐌 snail
🐞 lady_beetle ladybug
🐢 turtle
🐍 snake
🦖 t-rex
🐙 octopus
🦀 crab
🐠 tropical_fish
🐟 fish
🐬 dolphin
🐳 whale spouting_whale
🦈 shark
🐘 elephant
🦒 giraffe
🐕 dog2
🐈 cat2
🌵 cactus
🎄 christmas_tree
🌲 evergreen_tree
🌳 deciduous_tree
🌴 palm_tree
🌱 seedling
🌿 herb
☘️ shamrock
🍀 four_leaf_clover
🍁 maple_leaf
🍂 fallen_leaf
🍃 leaves leaf_fluttering_in_wind
🌷 tulip
🌹 rose
🌺 hibiscus
🌸 cherry_blossom
🌼 blossom
🌻 sunflower
💐 bouquet
🍄 mushroom
🌍 earth_africa globe_showing_europe_africa
🌎 earth_americas globe_showing_americas
🌏 earth_asia globe_showing_asia_australia
🌐 globe_with_meridians
🌙 moon crescent_moon
🌑 new_moon
🌕 full_moon
⭐ star
🌟 star2 glowing_star
✨ sparkles
⚡ zap high_voltage
🔥 fire
🌈 rainbow
☀️ sunny sun
⛅ partly_sunny sun_behind_cloud
☁️ cloud
🌧️ cloud_with_rain
⛈️ cloud_with_lightning_and_rain
❄️ snowflake
☃️ snowman
⛄ snowman_without_snow
🌊 ocean water_wave
💧 droplet
☔ umbrella umbrella_with_rain_drops
🌪️ tornado
🌫️ fog
🍏 green_apple
🍎 apple red_apple
🍐 pear
🍊 tangerine orange
🍋 lemon
🍌 banana
🍉 watermelon
🍇 grapes
🍓 strawberry
🫐 blueberries
🍒 cherries
🍑 peach
🥭 mango
🍍 pineapple
🥥 coconut
🥝 kiwi_fruit
🍅 tomato
🥑 avocado
🍆 eggplant
🥔 potato
🥕 carrot
🌽 corn ear_of_corn
🌶️ hot_pepper
🥒 cucumber
🥬 leafy_green
🥦 broccoli
🧄 garlic
🧅 onion
🍞 bread
🥐 croissant
🥖 baguette_bread
🥨 pretzel
🧀 cheese cheese_wedge
🥚 egg
🍳 fried_egg cooking
🥞 pancakes
🧇 waffle
🥓 bacon
🍔 hamburger
🍟 fries french_fries
🍕 pizza
🌭 hotdog hot_dog
🥪 sandwich
🌮 taco
🌯 burrito
🥗 salad green_salad
🍝 spaghetti
🍜 ramen steaming_bowl
🍲 stew pot_of_food
🍣 sushi
🍱 bento bento_box
🍚 rice cooked_rice
🍦 icecream soft_ice_cream
🍩 doughnut
🍪 cookie
🎂 birthday birthday_cake
🍰 cake shortcake
🧁 cupcake
🥧 pie
🍫 chocolate_bar
🍬 candy
🍭 lollipop
🍯 honey_pot
☕ coffee hot_beverage
🍵 tea teacup_without_handle
🧃 beverage_box
🥤 cup_with_straw
🍺 beer beer_mug
🍻 beers clinking_beer_mugs
🍷 wine_glass
🥂 clinking_glasses
🍸 cocktail cocktail_glass
🍽️ fork_and_knife_with_plate
🍴 fork_and_knife
⚽ soccer soccer_ball
🏀 basketball
🏈 football american_football
⚾ baseball
🎾 tennis
🏐 volleyball
🏓 ping_pong
🏸 badminton
⛳ golf flag_in_hole
🎣 fishing_pole_and_fish fishing_pole
🎽 running_shirt
🎿 ski skis
⛸️ ice_skate
🏆 trophy
🥇 first_place_medal 1st_place_medal
🥈 second_place_medal 2nd_place_medal
🥉 third_place_medal 3rd_place_medal
🏅 medal sports_medal
🎖️ military_medal
🎯 dart direct_hit bullseye
🎮 video_game
🎲 game_die
🧩 jigsaw puzzle_piece
♟️ chess_pawn
🎨 art artist_palette
🎭 performing_arts
🎬 clapper clapper_board
🎤 microphone
🎧 headphones headphone
🎼 musical_score
🎵 musical_note
🎶 notes musical_notes
🎹 musical_keyboard
🥁 drum
🎷 saxophone
🎸 guitar
🎺 trumpet
🎻 violin
🚗 car red_car automobile
🚕 taxi
🚌 bus
🚓 police_car
🚑 ambulance
🚒 fire_engine
🚚 truck delivery_truck
🚲 bike bicycle
🛴 kick_scooter
🏍️ motorcycle
🚂 steam_locomotive
🚆 train
🚇 metro
✈️ airplane
🛫 airplane_departure
🛬 airplane_arrival
🚀 rocket
🛸 flying_saucer
🚁 helicopter
⛵ sailboat
🚢 ship
⚓ anchor
⛽ fuelpump fuel_pump
🚦 traffic_light vertical_traffic_light
🚧 construction
🗺️ world_map
🧭 compass
🏔️ snow_capped_mountain
⛰️ mountain
🌋 volcano
🏕️ camping
🏖️ beach_with_umbrella beach
🏝️ desert_island
🏠 house
🏡 house_with_garden
🏢 office office_building
🏥 hospital
🏦 bank
🏨 hotel
🏫 school
🏛️ classical_building
⛪ church
🕌 mosque
🗽 statue_of_liberty
🗼 tokyo_tower
🏰 castle european_castle
🎡 ferris_wheel
🎢 roller_coaster
⌚ watch
📱 iphone mobile_phone
💻 computer laptop
⌨️ keyboard
🖥️ desktop_computer
🖨️ printer
🖱️ computer_mouse
💾 floppy_disk
💿 cd optical_disk
📷 camera
📸 camera_flash camera_with_flash
📹 video_camera
🎥 movie_camera
📞 telephone_receiver
☎️ phone telephone
📺 tv television
📻 radio
⏰ alarm_clock
⏳ hourglass_flowing_sand
⌛ hourglass hourglass_done
🔋 battery
🔌 electric_plug
💡 bulb light_bulb idea
🔦 flashlight
🕯️ candle
💸 money_with_wings
💵 dollar dollar_banknote
💶 euro euro_banknote
💰 moneybag money_bag
💳 credit_card
💎 gem gem_stone
⚖️ balance_scale
🔧 wrench
🔨 hammer
⚒️ hammer_and_pick
🛠️ hammer_and_wrench
🔩 nut_and_bolt
⚙️ gear
🧰 toolbox
🧲 magnet
🧪 test_tube
🧫 petri_dish
🧬 dna
🔬 microscope
🔭 telescope
📡 satellite satellite_antenna
💉 syringe
💊 pill
🩺 stethoscope
🚪 door
🛏️ bed
🛋️ couch_and_lamp
🚽 toilet
🚿 shower
🛁 bathtub
🧹 broom
🧺 basket
🧻 roll_of_paper
🧼 soap
🛒 shopping_cart
🎁 gift wrapped_gift
🎈 balloon
🎉 tada party_popper
🎊 confetti_ball
🎀 ribbon
🎃 jack_o_lantern
🎆 fireworks
🎇 sparkler
🧨 firecracker
🎗️ reminder_ribbon
🎟️ admission_tickets
🎫 ticket
✉️ envelope email
📧 e-mail
📨 incoming_envelope
📩 envelope_with_arrow
📤 outbox_tray
📥 inbox_tray
📦 package
📫 mailbox closed_mailbox_with_raised_flag
📮 postbox
✏️ pencil2 pencil
✒️ black_nib
🖋️ fountain_pen
🖊️ pen
🖌️ paintbrush
🖍️ crayon
📝 memo pencil_memo
💼 briefcase
📁 file_folder
📂 open_file_folder
🗂️ card_index_dividers
📅 date calendar
📆 calendar spiral_calendar tear_off_calendar
🗒️ spiral_notepad
📇 card_index
📈 chart_with_upwards_trend chart_increasing
📉 chart_with_downwards_trend chart_decreasing
📊 bar_chart
📋 clipboard
📌 pushpin
📍 round_pushpin
📎 paperclip
🖇️ linked_paperclips
📏 straight_ruler ruler
📐 triangular_ruler
✂️ scissors
🗃️ card_file_box
🗄️ file_cabinet
🗑️ wastebasket
🔒 lock locked
🔓 unlock unlocked
🔏 lock_with_ink_pen
🔐 closed_lock_with_key
🔑 key
🗝️ old_key
📓 notebook
📔 notebook_with_decorative_cover
📒 ledger
📕 closed_book red_book
📗 green_book
📘 blue_book
📙 orange_book
📚 books
📖 book open_book
🔖 bookmark
🏷️ label
📰 newspaper
🗞️ rolled_up_newspaper
📄 page_facing_up
📃 page_with_curl
📜 scroll
🧾 receipt
🔍 mag magnifying_glass_tilted_left
🔎 mag_right magnifying_glass_tilted_right
🔗 link
🧮 abacus
🎓 mortar_board graduation_cap
🏁 checkered_flag chequered_flag
🚩 triangular_flag_on_post triangular_flag
🏳️ white_flag
🏴 black_flag
🏳️‍🌈 rainbow_flag
✅ white_check_mark check_mark_button
☑️ ballot_box_with_check check_box_with_check
✔️ heavy_check_mark check_mark
❌ x cross_mark
❎ negative_squared_cross_mark cross_mark_button
➕ heavy_plus_sign plus
➖ heavy_minus_sign minus
➗ heavy_division_sign divide
✖️ heavy_multiplication_x multiply
❓ question question_mark red_question_mark
❔ grey_question white_question_mark
❗ exclamation heavy_exclamation_mark red_exclamation_mark
❕ grey_exclamation white_exclamation_mark
‼️ bangbang double_exclamation_mark
⁉️ interrobang exclamation_question_mark
⚠️ warning
🚫 no_entry_sign prohibited
⛔ no_entry
⭕ o hollow_red_circle
🔴 red_circle
🟠 orange_circle
🟡 yellow_circle
🟢 green_circle
🔵 large_blue_circle blue_circle
🟣 purple_circle
⚫ black_circle
⚪ white_circle
🟥 red_square
🟧 orange_square
🟨 yellow_square
🟩 green_square
🟦 blue_square
🟪 purple_square
⬛ black_large_square
⬜ white_large_square
🔶 large_orange_diamond
🔷 large_blue_diamond
🔺 small_red_triangle red_triangle_pointed_up
🔻 small_red_triangle_down red_triangle_pointed_down
➡️ arrow_right right_arrow
⬅️ arrow_left left_arrow
⬆️ arrow_up up_arrow
⬇️ arrow_down down_arrow
↩️ leftwards_arrow_with_hook right_arrow_curving_left
↪️ arrow_right_hook left_arrow_curving_right
🔄 arrows_counterclockwise counterclockwise_arrows_button
🔁 repeat repeat_button
🔀 twisted_rightwards_arrows shuffle_tracks_button
▶️ arrow_forward play_button
⏸️ pause_button
⏹️ stop_button
⏺️ record_button
⏩ fast_forward fast_forward_button
⏪ rewind fast_reverse_button
🔔 bell
🔕 no_bell bell_with_slash
📣 mega megaphone
📢 loudspeaker
🔊 loud_sound speaker_high_volume
🔇 mute muted_speaker
♻️ recycle recycling_symbol
⚛️ atom_symbol
☮️ peace_symbol
☯️ yin_yang
♾️ infinity
💲 heavy_dollar_sign
©️ copyright
®️ registered
™️ tm trade_mark
#️⃣ hash keycap_hash
0️⃣ zero keycap_0
1️⃣ one keycap_1
2️⃣ two keycap_2
3️⃣ three keycap_3
4️⃣ four keycap_4
5️⃣ five keycap_5
6️⃣ six keycap_6
7️⃣ seven keycap_7
8️⃣ eight keycap_8
9️⃣ nine keycap_9
🔟 keycap_ten
🆕 new new_button
🆗 ok ok_button
🆒 cool cool_button
🆓 free free_button
🆘 sos sos_button
🆙 up up_button
ℹ️ information_source information
🔝 top top_arrow
🔜 soon soon_arrow
🔚 end end_arrow
🕐 clock1 one_oclock
🕒 clock3 three_oclock
🕕 clock6 six_oclock
🕘 clock9 nine_oclock
🕛 clock12 twelve_oclock
🌡️ thermometer
🧊 ice
🗓️ spiral_calendar_pad
📬 mailbox_with_mail
🪴 potted_plant
🪐 ringed_planet
🌌 milky_way
🌅 sunrise
🌄 sunrise_over_mountains
🌃 night_with_stars
🌆 city_sunset cityscape_at_dusk
🏙️ cityscape
🗻 mount_fuji
🎒 school_satchel backpack
👓 eyeglasses glasses
🕶️ dark_sunglasses
👔 necktie
👕 shirt tshirt t-shirt
👖 jeans
👗 dress
👟 athletic_shoe running_shoe
👠 high_heel high_heeled_shoe
👑 crown
🎩 tophat top_hat
🧢 billed_cap
💍 ring
💄 lipstick
🧳 luggage
☂️ open_umbrella
🌂 closed_umbrella
🪄 magic_wand
🔮 crystal_ball
🧸 teddy_bear
🪁 kite
🛹 skateboard
🏋️ weight_lifter person_lifting_weights
🚴 bicyclist person_biking
🏊 swimmer person_swimming
🧗 person_climbing
🏄 surfer person_surfing
"""
}
