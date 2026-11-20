import Foundation

/// Text for the OCR hill-climb test set. Markup: <i>italic</i>, <sc>small caps</sc>,
/// <g>Greek</g>. English is original or from public-domain translations (Jowett's
/// Plato); Greek, Latin and German are from public-domain authors. The truth for
/// each page is whatever the typesetter actually put on it, so a slip in a quotation
/// can't make the score wrong.
enum HCCorpus {

    static let english: [String] = [
        "The study of ancient philosophy has, since the middle of the nineteenth century, been governed by two opposing habits of mind. The first treats the dialogues of Plato as a finished system whose doctrines may be extracted, catalogued, and compared with the teaching of later schools. The second insists that each dialogue is a self-contained argument, addressed to a particular audience, and that no conclusion drawn from one may be carried into another without careful proof. Neither habit is wholly mistaken, but each, followed without restraint, leads the student away from the text.",
        "In the early Roman Republic the magistrates were few, their terms were short, and their powers, though large, were hedged about by custom. A consul who held the fasces for a year might lead an army, preside over the Senate, and judge a case at law, yet he could not remain in office beyond his term, and when it ended he returned to private life exposed to prosecution for what he had done. It is this mixture of strong authority and strict accountability, rather than any single statute, that gave the Roman constitution its remarkable stability during the fourth and third centuries before our era.",
        "The manuscripts of the text fall into two families which differ chiefly in the order of the later chapters. The older family is represented by a single codex of the tenth century, now preserved in a monastic library in the north of Italy; it is carefully written, but its scribe has omitted a number of lines through the repetition of similar endings. The younger family descends from a lost copy made at Constantinople about the year 1300, and it contains many readings that are plainly the work of a learned corrector. An editor must therefore weigh each variant on its own merits, and must not suppose that the antiquity of a witness guarantees the excellence of its readings.",
        "We left the village at dawn, when the mist still lay in the hollows of the valley and the shepherds were driving their flocks to the upper pastures. The road, if it deserves the name, followed the bed of a stream for several miles, and then climbed by a series of steep turns to a pass from which we could see the whole range of mountains stretched out before us. My guide, an old man who had served in the army of the prince, pointed out the peaks one by one, and told me the names which the people of the country give them.",
        "The reign of the second Edward is commonly described as a period of weakness, and the chroniclers of his own day were quick to blame the king for every misfortune that befell the realm. But the evidence of the records tells a more complicated story. The machinery of government continued to work; the courts sat, the taxes were collected, and the Parliament, which met more often than in any earlier reign, gradually acquired the habit of presenting petitions and receiving answers. If the king failed, he failed as a man, not as the head of an administration which had grown too strong to be overthrown by the faults of one person.",
        "Every student of language knows that sounds change, and that they change according to rules which admit of very few exceptions. A word which is pronounced in one way by the grandfather will be pronounced differently by the grandson, yet neither of them is conscious of any alteration. The patient comparison of related tongues has made it possible to recover, with a fair degree of certainty, the forms which the common ancestors of those tongues must have used, and to show that apparent resemblances between unrelated languages are nearly always the work of chance.",
        "The aim of education, as the older writers conceived it, was not to fill the mind with information but to form the character; and for this purpose the study of a few great books, read slowly and repeated until they were known by heart, was thought to be far more useful than a hasty acquaintance with many. We may smile at the narrowness of this ideal, but we should not forget that the men who were brought up on it governed empires, wrote histories which are still read, and left behind them a standard of public conduct by which their successors have been judged.",
        "The observations of the planets which were made at Babylon over many centuries furnished the Greek astronomers with a store of exact data such as they could never have collected for themselves. Hipparchus, who worked in the second century before Christ, used these records to determine the length of the year and the motion of the moon with a precision that was not surpassed until the age of Copernicus. It is to be regretted that nearly all his writings have perished, and that we are obliged to reconstruct his methods from the brief and sometimes careless report of a later author.",
        "The council met in the summer of the year, and its first business was to examine the credentials of the bishops who had come from the distant provinces. Disputes over precedence consumed several days, and it was only after the emperor had sent a letter urging haste that the assembly turned to the question of doctrine. The debates which followed were long and bitter, and the surviving accounts, written for the most part by partisans of one side or the other, can hardly be reconciled with one another.",
        "The agriculture of the district depended almost entirely upon the rainfall of the winter months. In a good year the barley was ripe by the end of April and the wheat a few weeks later; in a bad year the farmer might harvest hardly more than he had sown. For this reason the larger landowners kept great store of grain in underground chambers, and sold it in time of scarcity at prices which the poorer cultivators could seldom afford, so that debt, and in the end the loss of the land itself, became the common lot of the small man.",
        "It is a mistake to suppose that the poetry of an age can be understood by reading only the best of it. The minor writers, whose names are now remembered by scholars alone, show us what was commonly thought and said; they supply the background against which the achievement of a great poet must be measured. Without them we should not know which of his devices were new, and which were merely the stock in trade of his time, and we should be apt to admire as original what his contemporaries would have recognised at once as familiar.",
        "The principle that no man may be judge in his own cause is older than any written code, and it appears in some form in the legal usage of every settled community. Yet the application of it has never been free from difficulty. Is a magistrate disqualified because he owns a share in a company which is a party to the suit? Or because he has expressed an opinion on the matter in conversation? The courts have answered such questions differently at different times, and the answers show how far the conception of fairness depends upon the habits and expectations of the society which holds it.",
        "The builders of the great cathedrals had no knowledge of the mathematical theory of stresses, and yet their vaults have stood for seven hundred years. They worked by rule of thumb, handing down from master to apprentice a stock of proportions which experience had shown to be safe. When a wall cracked, or a pier began to lean, the remedy was found by trial; and the records of the fabric, where they survive, show how many of the finest features of the building arose from the correction of a mistake.",
        "A historian who sets out to describe the causes of a war soon finds that he has too many of them. There are the quarrels of the rulers, the ambitions of the generals, the grievances of the merchants, and the long memory of old injuries; and each of these may be made to bear the whole weight of the explanation if the writer is clever enough. The best narratives are those which resist this temptation, and which allow the reader to see how many different things had to happen before the fatal step was taken.",
        "Among the papers of the family there are some three hundred letters, written between the years 1740 and 1790, which throw a curious light upon the daily life of a country household. They deal with the price of corn and the health of the horses, with the marriage of a niece and the misconduct of a steward, and now and then, in a postscript, with the great events of the time, which are mentioned briefly, as though they were of less consequence than the weather.",
        "The birds of the marshes are best observed in the early morning, when the wind has dropped and the surface of the water is still. The heron stands motionless at the edge of the reeds, waiting for a fish to come within reach of its bill; the coot swims out from the shelter of the rushes with its curious jerking motion; and high overhead the plover wheel and cry. A patient watcher, who does not move or speak, will be rewarded by a sight of many creatures which are never seen by the casual walker.",
        "A translator is always in danger of choosing between two evils. If he follows the original closely, he produces a version which is faithful in every word and yet strange to the ear; if he allows himself freedom, he writes good English at the cost of leaving out something that the author meant. The wise course lies between the two, but no rule can tell him exactly where. In the end he must trust his own sense of what the writer would have said, had he been born into the language of the reader.",
    ]

    /// Jowett's Plato and the King James Bible (public domain), as prose paragraphs.
    static let quoted: [String] = [
        "I went down yesterday to the Piraeus with Glaucon the son of Ariston, that I might offer up my prayers to the goddess; and also because I wanted to see in what manner they would celebrate the festival, which was a new thing. I was delighted with the procession of the inhabitants; but that of the Thracians was equally, if not more, beautiful. When we had finished our prayers and viewed the spectacle, we turned in the direction of the city.",
        "How you, O Athenians, have been affected by my accusers, I cannot tell; but I know that they almost made me forget who I was, so persuasively did they speak; and yet they have hardly uttered a word of truth. But of the many falsehoods told by them, there was one which quite amazed me; I mean when they said that you should be upon your guard and not allow yourselves to be deceived by the force of my eloquence.",
        "In the beginning God created the heaven and the earth. And the earth was without form, and void; and darkness was upon the face of the deep. And the Spirit of God moved upon the face of the waters. And God said, Let there be light: and there was light. And God saw the light, that it was good: and God divided the light from the darkness. And God called the light Day, and the darkness he called Night. And the evening and the morning were the first day.",
        "Though I speak with the tongues of men and of angels, and have not charity, I am become as sounding brass, or a tinkling cymbal. And though I have the gift of prophecy, and understand all mysteries, and all knowledge; and though I have all faith, so that I could remove mountains, and have not charity, I am nothing. Charity suffereth long, and is kind; charity envieth not; charity vaunteth not itself, is not puffed up.",
        "To every thing there is a season, and a time to every purpose under the heaven: a time to be born, and a time to die; a time to plant, and a time to pluck up that which is planted; a time to kill, and a time to heal; a time to break down, and a time to build up; a time to weep, and a time to laugh; a time to mourn, and a time to dance.",
    ]

    /// Paragraphs with italic and small-caps words.
    static let styled: [String] = [
        "The <sc>Annals</sc> of Tacitus were written, for the most part, in the principate of <sc>Trajan</sc>, though the exact date is uncertain. The <i>Histories</i> had been composed earlier, and the author himself refers in the <i>Agricola</i> to a work which he intended to write on the reigns of <sc>Nerva</sc> and Trajan. Whether this plan was ever carried out is not known; <i>nunquam</i> is the word used by some editors, who think the design was abandoned.",
        "In the second edition, published at <sc>London</sc> in 1788, the author has added a long note on the use of the word <i>constitution</i>, which he now admits to be ambiguous. He had meant by it the whole body of laws and customs; his critics, as he complains, understood only the written instrument. The <i>Federalist</i> had already drawn the distinction, but he seems not to have read it until the book was in print.",
        "The word <i>virtus</i> in the age of <sc>Cicero</sc> still carries something of its early sense of manly courage, though the philosophers had begun to use it for moral excellence in general. A writer who rendered it everywhere by <i>virtue</i> would give the English reader a false impression; one who rendered it everywhere by <i>courage</i> would give a false impression of another kind. The <sc>Stoic</sc> usage, which was the commonest in the schools, lies between.",
        "The ship, called the <i>Santa Maria</i> by the Spanish chroniclers and the <i>Gallega</i> by the sailors, was of about a hundred tons, and carried a crew of forty. Of her later history little is known; the <sc>Admiral</sc> himself, in a letter written from <sc>Lisbon</sc> in the spring, speaks only of her loss on the coast of Hispaniola, and passes on at once to the question of the colony.",
        "In the printed catalogue the entry reads: <i>Codex Ambrosianus</i>, a copy of the <i>Iliad</i> on vellum, of the fifth or sixth century, with the pictures of the <sc>Homeric</sc> scenes which give the manuscript its fame. The <sc>Iliad</sc> text is fragmentary, but the scholia in the margin, written in a small uncial hand, have preserved many readings that are found nowhere else.",
        "Of the three <sc>Fates</sc> the poet names only one, <i>Clotho</i>, and he describes her not as a spinner but as a weaver; the <i>Moirai</i> of <sc>Hesiod</sc> are quite different, and the confusion has led more than one commentator astray. It is wise to remember that the popular names of the Fates are late, and that the earliest authors speak of a single power, <i>Moira</i>, without distinction of persons.",
        "The Jesuit <sc>Mariana</sc>, in the <i>Historiae de rebus Hispaniae</i>, gives an account of the siege which differs in several particulars from that of the <sc>Moorish</sc> chroniclers; where they agree, however, we may feel some confidence that the facts are as stated. The <i>Chronicle</i> of the Cid, which is later, follows <sc>Mariana</sc> in the main, but adds a number of details of its own.",
    ]

    /// English with polytonic Greek words and phrases, as in a scholarly book.
    static let greekMixed: [String] = [
        "The word <g>λόγος</g> is among the hardest in the Greek language to render, for it means at once speech, reason, account, and proportion. In Heraclitus it seems to denote the common law that governs the changes of the world; in Plato it is most often the explanation which a man can give of what he knows; and in the opening verse of the Fourth Gospel, <g>ἐν ἀρχῇ ἦν ὁ λόγος</g>, it is the divine Word through which all things came to be.",
        "Aristotle’s definition of man as a political animal, <g>ὁ ἄνθρωπος φύσει πολιτικὸν ζῷον</g>, is often quoted as though it were a statement about human sociability in general. The context in the <i>Politics</i> shows that it is nothing of the kind. The <g>πόλις</g> is for him a particular form of association, and only within it can the capacity for speech, <g>λόγος</g>, and for the perception of justice and injustice, <g>δίκαιον</g> and <g>ἄδικον</g>, be fully exercised.",
        "The Socratic paradox <g>οὐδεὶς ἑκὼν ἁμαρτάνει</g>, that no one does wrong willingly, has been explained in many ways. Some take <g>ἁμαρτάνειν</g> to mean intellectual error rather than moral fault; others point out that <g>ἀρετή</g> and <g>ἐπιστήμη</g> are for Socrates practically identical, so that to know the good is already to be good. Neither explanation is wholly satisfactory, but both are preferable to the view that Socrates was merely playing upon words.",
        "The inscription at Delphi, <g>γνῶθι σεαυτόν</g>, was understood by the Greeks as a warning against presumption, a reminder that the human being is mortal, <g>θνητός</g>, and must not claim the privileges of the gods, <g>θεοί</g>. Only later, in the schools of philosophy, did the precept come to mean an invitation to look inward at the <g>ψυχή</g>. The change of sense is a good example of how a famous phrase may be made to serve the purposes of each succeeding age.",
        "In the <i>Poetics</i> Aristotle says that tragedy is an imitation, <g>μίμησις</g>, of an action that is serious and complete, and that through pity and fear it effects the purgation, <g>κάθαρσις</g>, of such emotions. The meaning of <g>κάθαρσις</g> has been disputed since the sixteenth century. Is it a medical term, a religious one, or a metaphor from the lawcourts? The Greek text does not decide the matter, and the passage in the <i>Politics</i> which seems to promise further explanation gives none.",
        "Herodotus describes his work as an <g>ἱστορίης ἀπόδεξις</g>, a display of inquiry, and the word <g>ἱστορία</g> has in his usage not yet acquired the restricted sense of a narrative of past events. It means the process of finding out, by asking and looking; and the same root appears in the verb <g>ἱστορεῖν</g>, which Herodotus uses of travellers who question the priests of Egypt about their sacred records.",
        "The Heraclitean saying <g>πάντα ῥεῖ</g>, everything flows, does not occur in this form in any ancient text of Heraclitus himself, though Plato in the <i>Cratylus</i> attributes to him a very similar thought. The genuine fragments speak rather of the river into which one cannot step twice, and of the strife, <g>ἔρις</g>, that is justice, <g>δίκη</g>. The tag is therefore a summary made by later writers, and it should be cited as such.",
        "To the Greeks of the classical age happiness, <g>εὐδαιμονία</g>, was not a feeling but a condition of the whole life; hence Solon’s warning to Croesus that no man can be called happy until he is dead. The English word is a poor equivalent, and translators have often preferred <i>well-being</i> or <i>flourishing</i>, which at least avoid the suggestion of a passing mood. The concept is bound up with <g>ἀρετή</g>, excellence, since the happy man is the one whose powers are fully and well used.",
    ]

    static let greekVerse: [[String]] = [
        ["μῆνιν ἄειδε θεὰ Πηληϊάδεω Ἀχιλῆος",
         "οὐλομένην, ἣ μυρί᾽ Ἀχαιοῖς ἄλγε᾽ ἔθηκε,",
         "πολλὰς δ᾽ ἰφθίμους ψυχὰς Ἄϊδι προΐαψεν",
         "ἡρώων, αὐτοὺς δὲ ἑλώρια τεῦχε κύνεσσιν",
         "οἰωνοῖσί τε πᾶσι, Διὸς δ᾽ ἐτελείετο βουλή,",
         "ἐξ οὗ δὴ τὰ πρῶτα διαστήτην ἐρίσαντε",
         "Ἀτρεΐδης τε ἄναξ ἀνδρῶν καὶ δῖος Ἀχιλλεύς.",
         "τίς τ᾽ ἄρ σφωε θεῶν ἔριδι ξυνέηκε μάχεσθαι;",
         "Λητοῦς καὶ Διὸς υἱός· ὃ γὰρ βασιλῆϊ χολωθεὶς",
         "νοῦσον ἀνὰ στρατὸν ὄρσε κακήν, ὀλέκοντο δὲ λαοί,",
         "οὕνεκα τὸν Χρύσην ἠτίμασεν ἀρητῆρα",
         "Ἀτρεΐδης· ὃ γὰρ ἦλθε θοὰς ἐπὶ νῆας Ἀχαιῶν",
         "λυσόμενός τε θύγατρα φέρων τ᾽ ἀπερείσι᾽ ἄποινα,",
         "στέμματ᾽ ἔχων ἐν χερσὶν ἑκηβόλου Ἀπόλλωνος",
         "χρυσέῳ ἀνὰ σκήπτρῳ, καὶ λίσσετο πάντας Ἀχαιούς,",
         "Ἀτρεΐδα δὲ μάλιστα δύω, κοσμήτορε λαῶν·",
         "Ἀτρεΐδαι τε καὶ ἄλλοι ἐϋκνήμιδες Ἀχαιοί,",
         "ὑμῖν μὲν θεοὶ δοῖεν Ὀλύμπια δώματ᾽ ἔχοντες",
         "ἐκπέρσαι Πριάμοιο πόλιν, εὖ δ᾽ οἴκαδ᾽ ἱκέσθαι·",
         "παῖδα δ᾽ ἐμοὶ λῦσαί τε φίλην τά τ᾽ ἄποινα δέχεσθαι,",
         "ἁζόμενοι Διὸς υἱὸν ἑκηβόλον Ἀπόλλωνα."],
        ["ἄνδρα μοι ἔννεπε, Μοῦσα, πολύτροπον, ὃς μάλα πολλὰ",
         "πλάγχθη, ἐπεὶ Τροίης ἱερὸν πτολίεθρον ἔπερσεν·",
         "πολλῶν δ᾽ ἀνθρώπων ἴδεν ἄστεα καὶ νόον ἔγνω,",
         "πολλὰ δ᾽ ὅ γ᾽ ἐν πόντῳ πάθεν ἄλγεα ὃν κατὰ θυμόν,",
         "ἀρνύμενος ἥν τε ψυχὴν καὶ νόστον ἑταίρων.",
         "ἀλλ᾽ οὐδ᾽ ὣς ἑτάρους ἐρρύσατο, ἱέμενός περ·",
         "αὐτῶν γὰρ σφετέρῃσιν ἀτασθαλίῃσιν ὄλοντο,",
         "νήπιοι, οἳ κατὰ βοῦς Ὑπερίονος Ἠελίοιο",
         "ἤσθιον· αὐτὰρ ὁ τοῖσιν ἀφείλετο νόστιμον ἦμαρ.",
         "τῶν ἁμόθεν γε, θεά, θύγατερ Διός, εἰπὲ καὶ ἡμῖν."],
    ]

    static let greekProse: [String] = [
        "Ἐν ἀρχῇ ἦν ὁ λόγος, καὶ ὁ λόγος ἦν πρὸς τὸν θεόν, καὶ θεὸς ἦν ὁ λόγος. οὗτος ἦν ἐν ἀρχῇ πρὸς τὸν θεόν. πάντα δι᾽ αὐτοῦ ἐγένετο, καὶ χωρὶς αὐτοῦ ἐγένετο οὐδὲ ἕν. ὃ γέγονεν ἐν αὐτῷ ζωὴ ἦν, καὶ ἡ ζωὴ ἦν τὸ φῶς τῶν ἀνθρώπων· καὶ τὸ φῶς ἐν τῇ σκοτίᾳ φαίνει, καὶ ἡ σκοτία αὐτὸ οὐ κατέλαβεν.",
        "Ἐγένετο ἄνθρωπος, ἀπεσταλμένος παρὰ θεοῦ, ὄνομα αὐτῷ Ἰωάννης· οὗτος ἦλθεν εἰς μαρτυρίαν, ἵνα μαρτυρήσῃ περὶ τοῦ φωτός, ἵνα πάντες πιστεύσωσιν δι᾽ αὐτοῦ. οὐκ ἦν ἐκεῖνος τὸ φῶς, ἀλλ᾽ ἵνα μαρτυρήσῃ περὶ τοῦ φωτός. ἦν τὸ φῶς τὸ ἀληθινόν, ὃ φωτίζει πάντα ἄνθρωπον, ἐρχόμενον εἰς τὸν κόσμον.",
        "Ὅτι μὲν ὑμεῖς, ὦ ἄνδρες Ἀθηναῖοι, πεπόνθατε ὑπὸ τῶν ἐμῶν κατηγόρων, οὐκ οἶδα· ἐγὼ δ᾽ οὖν καὶ αὐτὸς ὑπ᾽ αὐτῶν ὀλίγου ἐμαυτοῦ ἐπελαθόμην, οὕτω πιθανῶς ἔλεγον. καίτοι ἀληθές γε ὡς ἔπος εἰπεῖν οὐδὲν εἰρήκασιν.",
        "Κατέβην χθὲς εἰς Πειραιᾶ μετὰ Γλαύκωνος τοῦ Ἀρίστωνος προσευξόμενός τε τῇ θεῷ καὶ ἅμα τὴν ἑορτὴν βουλόμενος θεάσασθαι τίνα τρόπον ποιήσουσιν ἅτε νῦν πρῶτον ἄγοντες.",
        "Θουκυδίδης Ἀθηναῖος ξυνέγραψε τὸν πόλεμον τῶν Πελοποννησίων καὶ Ἀθηναίων, ὡς ἐπολέμησαν πρὸς ἀλλήλους, ἀρξάμενος εὐθὺς καθισταμένου καὶ ἐλπίσας μέγαν τε ἔσεσθαι καὶ ἀξιολογώτατον τῶν προγεγενημένων, τεκμαιρόμενος ὅτι ἀκμάζοντές τε ἦσαν ἐς αὐτὸν ἀμφότεροι παρασκευῇ τῇ πάσῃ.",
        "Ἡροδότου Ἁλικαρνησσέος ἱστορίης ἀπόδεξις ἥδε, ὡς μήτε τὰ γενόμενα ἐξ ἀνθρώπων τῷ χρόνῳ ἐξίτηλα γένηται, μήτε ἔργα μεγάλα τε καὶ θωμαστά, τὰ μὲν Ἕλλησι τὰ δὲ βαρβάροισι ἀποδεχθέντα, ἀκλεᾶ γένηται, τά τε ἄλλα καὶ δι᾽ ἣν αἰτίην ἐπολέμησαν ἀλλήλοισι.",
        "Δαρείου καὶ Παρυσάτιδος γίγνονται παῖδες δύο, πρεσβύτερος μὲν Ἀρταξέρξης, νεώτερος δὲ Κῦρος· ἐπεὶ δὲ ἠσθένει Δαρεῖος καὶ ὑπώπτευε τελευτὴν τοῦ βίου, ἐβούλετο τὼ παῖδε ἀμφοτέρω παρεῖναι.",
        "Ἐπεὶ δὲ μιμοῦνται οἱ μιμούμενοι πράττοντας, ἀνάγκη δὲ τούτους ἢ σπουδαίους ἢ φαύλους εἶναι, ἢ βελτίονας καθ᾽ ἡμᾶς ἢ χείρονας ἢ καὶ τοιούτους.",
        "Πάντες ἄνθρωποι τοῦ εἰδέναι ὀρέγονται φύσει. σημεῖον δ᾽ ἡ τῶν αἰσθήσεων ἀγάπησις· καὶ γὰρ χωρὶς τῆς χρείας ἀγαπῶνται δι᾽ αὑτάς, καὶ μάλιστα τῶν ἄλλων ἡ διὰ τῶν ὀμμάτων.",
    ]

    static let latin: [String] = [
        "Gallia est omnis divisa in partes tres, quarum unam incolunt Belgae, aliam Aquitani, tertiam qui ipsorum lingua Celtae, nostra Galli appellantur. Hi omnes lingua, institutis, legibus inter se differunt. Gallos ab Aquitanis Garumna flumen, a Belgis Matrona et Sequana dividit.",
        "Quo usque tandem abutere, Catilina, patientia nostra? quam diu etiam furor iste tuus nos eludet? quem ad finem sese effrenata iactabit audacia? Nihilne te nocturnum praesidium Palati, nihil urbis vigiliae, nihil timor populi, nihil concursus bonorum omnium, nihil hic munitissimus habendi senatus locus, nihil horum ora voltusque moverunt?",
        "Arma virumque cano, Troiae qui primus ab oris Italiam, fato profugus, Laviniaque venit litora, multum ille et terris iactatus et alto vi superum saevae memorem Iunonis ob iram; multa quoque et bello passus, dum conderet urbem inferretque deos Latio, genus unde Latinum Albanique patres atque altae moenia Romae.",
    ]

    static let german: [String] = [
        "Aufklärung ist der Ausgang des Menschen aus seiner selbst verschuldeten Unmündigkeit. Unmündigkeit ist das Unvermögen, sich seines Verstandes ohne Leitung eines anderen zu bedienen. Selbst verschuldet ist diese Unmündigkeit, wenn die Ursache derselben nicht am Mangel des Verstandes, sondern der Entschließung und des Mutes liegt, sich seiner ohne Leitung eines anderen zu bedienen.",
        "Habe nun, ach! Philosophie, Juristerei und Medizin, und leider auch Theologie durchaus studiert, mit heißem Bemühn. Da steh ich nun, ich armer Tor! und bin so klug als wie zuvor; heiße Magister, heiße Doktor gar, und ziehe schon an die zehen Jahr herauf, herab und quer und krumm meine Schüler an der Nase herum.",
        "Die Überlieferung der Handschriften ist für diese Frage von entscheidender Bedeutung, und man wird die Ausgabe von Wilamowitz nicht ohne Vorsicht benutzen dürfen. Schon die ältesten Zeugen weichen in der Anordnung der Abschnitte voneinander ab, und die Verfasser der späteren Abschriften haben offenbar versucht, die Widersprüche durch eigene Zusätze zu beseitigen.",
    ]

    static let footnotes: [String] = [
        "See the discussion in Jaeger, <i>Paideia</i>, vol. i, pp. 12–18, and the literature cited there.",
        "The reading is that of the Ambrosian manuscript; the later copies have <i>et</i> for <i>ut</i>, which gives a different sense.",
        "Cf. Thucydides, i. 22. 4; Polybius, xii. 25b; and the remarks of Cornford in the preface to his translation.",
        "<i>Proceedings of the Royal Society</i>, vol. xxix (1879), p. 301, note 2; the figures are those of the original report.",
        "For this use of the word, see Liddell and Scott, <i>s.v.</i>, and the passages collected by Bonitz, <i>Index Aristotelicus</i>, 598 b 20.",
        "Burnet, <i>Early Greek Philosophy</i>, 4th ed., London, 1930, p. 133; the translation is my own, and differs slightly from his.",
        "Compare the letter of the twelfth of March, printed in the appendix to the second volume of the correspondence.",
        "Mommsen, <i>Römisches Staatsrecht</i>, vol. i, p. 217; the question is discussed afresh by later writers without any agreement.",
        "Plato, <i>Republic</i> 331c–d; Aristotle, <i>Nicomachean Ethics</i> 1094a1–3; and the commentary of Adam on the former passage.",
        "<i>Codex Parisinus</i> 1807, fol. 43 verso; the marginal note is in a later hand and has been partly cut away by the binder.",
    ]

    static let heads: [String] = [
        "The Rise of the Roman Republic",
        "Studies in Greek Thought",
        "On the Text of the Manuscripts",
        "Notes on the Constitution",
        "The Language of the Poets",
        "Letters of a Country Family",
    ]
}
